defmodule CredoLanguageServer do
  @moduledoc """
  LSP implementation for Credo.
  """
  use GenLSP

  alias GenLSP.ErrorResponse

  alias GenLSP.Enumerations.{
    CodeActionKind,
    DiagnosticSeverity,
    ErrorCodes,
    TextDocumentSyncKind
  }

  alias GenLSP.Notifications.{
    Exit,
    Initialized,
    TextDocumentDidChange,
    TextDocumentDidOpen,
    TextDocumentDidSave
  }

  alias GenLSP.Requests.{Initialize, Shutdown, TextDocumentCodeAction}

  alias GenLSP.Structures.{
    CodeActionContext,
    CodeActionOptions,
    CodeActionParams,
    CodeDescription,
    Diagnostic,
    DidOpenTextDocumentParams,
    InitializeParams,
    InitializeResult,
    Position,
    Range,
    SaveOptions,
    ServerCapabilities,
    TextDocumentIdentifier,
    TextDocumentItem,
    TextDocumentSyncOptions,
    WorkDoneProgressBegin,
    WorkDoneProgressEnd
  }

  alias CredoLanguageServer.Cache, as: Diagnostics

  def start_link(args) do
    {args, opts} =
      Keyword.split(args, [:cache, :task_supervisor, :runtime_supervisor])

    GenLSP.start_link(__MODULE__, args, opts)
  end

  @impl true
  def init(lsp, args) do
    cache = Keyword.fetch!(args, :cache)
    task_supervisor = Keyword.fetch!(args, :task_supervisor)
    runtime_supervisor = Keyword.fetch!(args, :runtime_supervisor)

    {:ok,
     assign(lsp,
       exit_code: 1,
       cache: cache,
       documents: %{},
       refresh_refs: %{},
       task_supervisor: task_supervisor,
       runtime_supervisor: runtime_supervisor,
       ready: false
     )}
  end

  @impl true
  def handle_request(
        %Initialize{params: %InitializeParams{root_uri: root_uri}},
        lsp
      ) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: true},
           change: TextDocumentSyncKind.full()
         },
         code_action_provider: %CodeActionOptions{
           code_action_kinds: [CodeActionKind.quick_fix()]
         }
       },
       server_info: %{name: "Credo"}
     }, assign(lsp, root_uri: root_uri)}
  end

  def handle_request(
        %TextDocumentCodeAction{
          params: %CodeActionParams{
            context: %CodeActionContext{diagnostics: diagnostics},
            text_document: %TextDocumentIdentifier{uri: uri}
          }
        },
        lsp
      ) do
    code_actions =
      for %Diagnostic{data: %{"check" => check}} = diagnostic <- diagnostics,
          check =
            CredoLanguageServer.Check.new(
              check: check,
              diagnostic: diagnostic,
              uri: uri,
              document: lsp.assigns.documents[uri]
            ),
          action <- CredoLanguageServer.CodeActionable.fetch(check) do
        action
      end

    {:reply, code_actions, lsp}
  end

  def handle_request(%Shutdown{}, lsp) do
    {:reply, nil, assign(lsp, exit_code: 0)}
  end

  def handle_request(%{method: method}, lsp) do
    GenLSP.warning(lsp, "[Credo] Method Not Found: #{method}")

    {:reply,
     %ErrorResponse{
       code: ErrorCodes.method_not_found(),
       message: "Method Not Found: #{method}"
     }, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.log(lsp, "[Credo] LSP Initialized!")

    token =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 8)

    GenLSP.notify(lsp, %GenLSP.Notifications.DollarProgress{
      params: %GenLSP.Structures.ProgressParams{
        token: token,
        value: %WorkDoneProgressBegin{
          kind: "begin",
          title: "Initializing Credo..."
        }
      }
    })

    working_dir = URI.parse(lsp.assigns.root_uri).path

    GenLSP.log(lsp, "[Credo] Booting runime...")

    {:ok, runtime} =
      DynamicSupervisor.start_child(
        lsp.assigns.runtime_supervisor,
        {CredoLanguageServer.Runtime,
         working_dir: working_dir, parent: self()}
      )

    Process.monitor(runtime)

    lsp = assign(lsp, runtime: runtime)

    task =
      Task.Supervisor.async_nolink(lsp.assigns.task_supervisor, fn ->
        with false <-
               wait_until(fn ->
                 CredoLanguageServer.Runtime.ready?(runtime)
               end) do
          GenLSP.error(lsp, "Failed to start runtime")
          raise "Failed to boot runtime"
        end

        GenLSP.log(lsp, "[Credo] Runtime ready...")

        with false <-
               wait_until(fn ->
                 match?(
                   {:ok, _},
                   CredoLanguageServer.Runtime.call(
                     runtime,
                     {Application, :ensure_all_started, [:credo]}
                   )
                 )
               end) do
          GenLSP.error(lsp, "Failed to start the Credo application")
          raise "Failed to start credo"
        end

        GenLSP.log(lsp, "[Credo] Credo started in runtime...")

        CredoLanguageServer.Runtime.call(
          runtime,
          {GenServer, :call,
           [Credo.CLI.Output.Shell, {:suppress_output, true}]}
        )

        count = refresh(lsp)
        publish(lsp)
        {:init, count}
      end)

    {:noreply,
     lsp
     |> (&put_in(&1.assigns.refresh_refs[task.ref], token)).()}
  end

  def handle_notification(
        %TextDocumentDidSave{},
        %{assigns: %{ready: false}} = lsp
      ) do
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidSave{
          params: %GenLSP.Structures.DidSaveTextDocumentParams{
            text: text,
            text_document: %{uri: uri}
          }
        },
        %{assigns: %{ready: true}} = lsp
      ) do
    token =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 8)

    GenLSP.notify(lsp, %GenLSP.Notifications.DollarProgress{
      params: %GenLSP.Structures.ProgressParams{
        token: token,
        value: %WorkDoneProgressBegin{
          kind: "begin",
          title: "Credo",
          message: "Finding issues..."
        }
      }
    })

    task =
      Task.Supervisor.async_nolink(lsp.assigns.task_supervisor, fn ->
        Diagnostics.clear(lsp.assigns.cache)
        count = refresh(lsp)
        publish(lsp)
        count
      end)

    {:noreply,
     lsp
     |> (&put_in(&1.assigns.documents[uri], String.split(text, "\n"))).()
     |> (&put_in(&1.assigns.refresh_refs[task.ref], token)).()}
  end

  def handle_notification(
        %TextDocumentDidChange{},
        %{assigns: %{ready: false}} = lsp
      ) do
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidChange{}, lsp) do
    for task <- Task.Supervisor.children(lsp.assigns.task_supervisor) do
      Process.exit(task, :kill)
    end

    Task.Supervisor.start_child(lsp.assigns.task_supervisor, fn ->
      Diagnostics.clear(lsp.assigns.cache)
      publish(lsp)
    end)

    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidOpen{
          params: %DidOpenTextDocumentParams{
            text_document: %TextDocumentItem{text: text, uri: uri}
          }
        },
        lsp
      ) do
    {:noreply, put_in(lsp.assigns.documents[uri], String.split(text, "\n"))}
  end

  def handle_notification(%Exit{}, lsp) do
    System.halt(lsp.assigns.exit_code)

    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  def handle_info({ref, resp}, %{assigns: %{refresh_refs: refs}} = lsp)
      when is_map_key(refs, ref) do
    Process.demonitor(ref, [:flush])
    {token, refs} = Map.pop(refs, ref)

    {lsp, count} =
      case resp do
        {:init, count} ->
          {assign(lsp, ready: true), count}

        count ->
          {lsp, count}
      end

    GenLSP.notify(lsp, %GenLSP.Notifications.DollarProgress{
      params: %GenLSP.Structures.ProgressParams{
        token: token,
        value: %WorkDoneProgressEnd{
          kind: "end",
          message: "Found #{count} issues"
        }
      }
    })

    {:noreply, assign(lsp, refresh_refs: refs)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{refresh_refs: refs}} = lsp
      )
      when is_map_key(refs, ref) do
    {token, refs} = Map.pop(refs, ref)

    GenLSP.notify(lsp, %GenLSP.Notifications.DollarProgress{
      params: %GenLSP.Structures.ProgressParams{
        token: token,
        value: %WorkDoneProgressEnd{
          kind: "end"
        }
      }
    })

    {:noreply, assign(lsp, refresh_refs: refs)}
  end

  def handle_info(
        {:DOWN, _ref, :process, runtime, _reason},
        %{assigns: %{runtime: runtime}} = lsp
      ) do
    GenLSP.error(lsp, "[Credo] The Credo runtime has crashed")

    {:noreply, assign(lsp, runtime: nil)}
  end

  def handle_info({:log, message}, lsp) do
    GenLSP.log(lsp, String.trim(message))

    {:noreply, lsp}
  end

  def handle_info(_, lsp) do
    {:noreply, lsp}
  end

  defp refresh(lsp) do
    dir = URI.parse(lsp.assigns.root_uri).path

    issues =
      CredoLanguageServer.Runtime.call(
        lsp.assigns.runtime,
        {:_credo_language_server_private_credo, :issues, [dir]}
      )

    for issue <- issues do
      diagnostic = %Diagnostic{
        range: %Range{
          start: %Position{
            line: issue.line_no - 1,
            character: (issue.column || 1) - 1
          },
          end: %Position{
            line: issue.line_no - 1,
            character: issue.column || 1
          }
        },
        severity: category_to_severity(issue.category),
        data: %{check: issue.check, file: issue.filename},
        source: "credo",
        code: Macro.to_string(issue.check),
        code_description: %CodeDescription{
          href:
            "https://hexdocs.pm/credo/#{Macro.to_string(issue.check)}.html"
        },
        message: issue.message
      }

      Diagnostics.put(
        lsp.assigns.cache,
        Path.join(lsp.assigns.root_uri, issue.filename)
        |> URI.parse()
        |> Map.get(:path),
        diagnostic
      )
    end

    Enum.count(issues)
  end

  defp publish(lsp) do
    for {file, diagnostics} <- Diagnostics.get(lsp.assigns.cache) do
      GenLSP.notify(lsp, %GenLSP.Notifications.TextDocumentPublishDiagnostics{
        params: %GenLSP.Structures.PublishDiagnosticsParams{
          uri: "file://#{file}",
          diagnostics: diagnostics
        }
      })
    end
  end

  defp category_to_severity(:refactor), do: DiagnosticSeverity.error()
  defp category_to_severity(:warning), do: DiagnosticSeverity.warning()
  defp category_to_severity(:design), do: DiagnosticSeverity.information()

  defp category_to_severity(:consistency),
    do: DiagnosticSeverity.information()

  defp category_to_severity(:readability),
    do: DiagnosticSeverity.information()

  defp wait_until(cb) do
    wait_until(120, cb)
  end

  defp wait_until(0, _cb) do
    false
  end

  defp wait_until(n, cb) do
    if cb.() do
      true
    else
      Process.sleep(1000)
      wait_until(n - 1, cb)
    end
  end
end
