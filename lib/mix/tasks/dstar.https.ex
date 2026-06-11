defmodule Mix.Tasks.Dstar.Https do
  @shortdoc "Sets up trusted HTTPS for dev: hosts entry + mkcert certificate"

  @moduledoc """
  Adds a development host to `/etc/hosts` and generates a browser-trusted
  development certificate with `mkcert`, so Datastar SSE streams run over
  HTTP/2 in dev without certificate warnings.

  The task infers the host from:

      config :my_app, dstar: [dev_url: "https://my-app.test:4001"]

  If no `:dev_url` is configured, it falls back to the current Mix application
  name with underscores converted to hyphens (e.g. `my-app.test`).

  This task asks before running local machine setup. If accepted, it may prompt
  for your password through `sudo` when updating `/etc/hosts` or when `mkcert`
  installs its local certificate authority. When `sudo` cannot prompt (e.g.
  some IDE terminals), it falls back to a GUI prompt on macOS via `osascript`.

  `mkcert` must be installed first. On macOS:

      brew install mkcert nss

  After the certificate is generated, point your endpoint at it in
  `config/dev.exs`:

      config :my_app, MyAppWeb.Endpoint,
        url: [scheme: "https", host: "my-app.test", port: 4001],
        https: [
          port: 4001,
          cipher_suite: :strong,
          keyfile: "priv/cert/selfsigned_key.pem",
          certfile: "priv/cert/selfsigned.pem"
        ]

  ## Examples

      mix dstar.https
      mix dstar.https --host my-app.test
      mix dstar.https --cert priv/cert/selfsigned.pem
      mix dstar.https --key priv/cert/selfsigned_key.pem
      mix dstar.https --yes

  ## Options

    * `--host` - hostname to add and generate a certificate for. Defaults to
      the configured Dstar dev URL host.
    * `--cert` - certificate path. Defaults to `priv/cert/selfsigned.pem`.
    * `--key` - private key path. Defaults to `priv/cert/selfsigned_key.pem`.
    * `--ip` - IP address for the hosts entry. Defaults to `127.0.0.1`.
    * `--dry-run` - print the commands without running them.
    * `--yes` - skip the confirmation prompt.
  """

  use Mix.Task

  @default_cert_path "priv/cert/selfsigned.pem"
  @default_key_path "priv/cert/selfsigned_key.pem"
  @default_hosts_file "/etc/hosts"
  @default_ip "127.0.0.1"

  @switches [
    cert: :string,
    dry_run: :boolean,
    host: :string,
    hosts_file: :string,
    ip: :string,
    key: :string,
    yes: :boolean
  ]
  @aliases [c: :cert, h: :host]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {options, args, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    validate_args!(args, invalid)

    app_name = Mix.Project.config() |> Keyword.fetch!(:app)
    host = Keyword.get(options, :host) || configured_host(app_name) || dev_host(app_name)
    ip = Keyword.get(options, :ip, @default_ip)
    cert_path = options |> Keyword.get(:cert, @default_cert_path) |> Path.expand()
    key_path = options |> Keyword.get(:key, @default_key_path) |> Path.expand()
    hosts_file = Keyword.get(options, :hosts_file, @default_hosts_file)
    dry_run? = Keyword.get(options, :dry_run, false)
    yes? = Keyword.get(options, :yes, false)

    validate_host!(host)
    validate_ip!(ip)
    validate_hosts_entry!(host, ip, hosts_file)

    if confirmed?(host, yes?, dry_run?) do
      ensure_mkcert!(dry_run?)
      install_mkcert_ca(dry_run?)
      add_hosts_entry(host, ip, hosts_file, dry_run?)
      generate_certificate(host, cert_path, key_path, dry_run?)

      Mix.shell().info("""
      Dstar HTTPS setup complete for https://#{host}.

      Point your endpoint at the certificate in config/dev.exs (see
      `mix help dstar.https` for the snippet), restart the server if it was
      already running, and restart your browser if it cached a previous
      certificate error.
      """)
    else
      Mix.shell().info("Skipped Dstar HTTPS setup. You can run `mix dstar.https` later.")
    end
  end

  @doc false
  def configured_host(app_name) do
    app_name
    |> Application.get_env(:dstar, [])
    |> Keyword.get(:dev_url)
    |> host_from_dev_url()
  end

  @doc false
  def dev_host(app_name) do
    app_name
    |> to_string()
    |> String.replace("_", "-")
    |> Kernel.<>(".test")
  end

  @doc false
  def host_from_dev_url(nil), do: nil

  def host_from_dev_url(dev_url) when is_binary(dev_url) do
    case URI.parse(dev_url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def host_from_dev_url(_), do: nil

  @doc false
  def hosts_entry_ip(contents, host) do
    contents
    |> hosts_entry_ips(host)
    |> List.first()
  end

  @doc false
  def hosts_entry_ips(contents, host) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      line
      |> strip_hosts_comment()
      |> String.split()
      |> case do
        [ip | aliases] ->
          if host in aliases, do: [ip], else: []

        _ ->
          []
      end
    end)
  end

  @doc false
  def hosts_append_command(host, ip, hosts_file) do
    entry = "#{ip} #{host}"

    "printf '\\n%s\\n' #{shell_quote(entry)} >> #{shell_quote(hosts_file)}"
  end

  @doc false
  def mkcert_certificate_args(host, cert_path, key_path) do
    [
      "-cert-file",
      cert_path,
      "-key-file",
      key_path,
      host,
      "localhost",
      "127.0.0.1",
      "::1"
    ]
  end

  defp add_hosts_entry(host, ip, hosts_file, dry_run?) do
    case File.read(hosts_file) do
      {:ok, contents} ->
        case hosts_entry_status(contents, host, ip) do
          :present ->
            Mix.shell().info("#{host} already exists in #{hosts_file}.")

          :missing ->
            append_hosts_entry(host, ip, hosts_file, dry_run?)

          {:conflict, existing_ips} ->
            raise_hosts_conflict!(host, hosts_file, existing_ips)
        end

      {:error, reason} ->
        Mix.shell().error("Could not read #{hosts_file}: #{:file.format_error(reason)}")
        append_hosts_entry(host, ip, hosts_file, dry_run?)
    end
  end

  defp validate_hosts_entry!(host, ip, hosts_file) do
    case File.read(hosts_file) do
      {:ok, contents} ->
        case hosts_entry_status(contents, host, ip) do
          {:conflict, existing_ips} -> raise_hosts_conflict!(host, hosts_file, existing_ips)
          _ -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp hosts_entry_status(contents, host, ip) do
    existing_ips = contents |> hosts_entry_ips(host) |> Enum.uniq()

    cond do
      existing_ips == [] -> :missing
      Enum.all?(existing_ips, &(&1 == ip)) -> :present
      true -> {:conflict, existing_ips}
    end
  end

  defp raise_hosts_conflict!(host, hosts_file, existing_ips) do
    Mix.raise("""
    #{host} already exists in #{hosts_file} with IP #{Enum.join(existing_ips, ", ")}.
    Leaving it unchanged.
    """)
  end

  defp append_hosts_entry(host, ip, hosts_file, dry_run?) do
    command = hosts_append_command(host, ip, hosts_file)

    Mix.shell().info("Adding #{host} to #{hosts_file} with sudo.")

    if dry_run? do
      Mix.shell().info("Would run: #{format_command("sudo", ["/bin/sh", "-c", command])}")
    else
      run_sudo_command(command, host, ip)
    end
  end

  defp install_mkcert_ca(dry_run?) do
    Mix.shell().info("Installing the local mkcert certificate authority if needed.")
    run_command("mkcert", ["-install"], dry_run?)
  end

  defp generate_certificate(host, cert_path, key_path, dry_run?) do
    ensure_certificate_directory!(cert_path, key_path, dry_run?)

    Mix.shell().info("""
    Generating mkcert certificate for #{host}, localhost, 127.0.0.1, and ::1.
    Certificate: #{cert_path}
    Key: #{key_path}
    """)

    run_command(
      "mkcert",
      mkcert_certificate_args(host, cert_path, key_path),
      dry_run?
    )
  end

  defp confirmed?(_host, true, _dry_run?), do: true
  defp confirmed?(_host, _yes?, true), do: true

  defp confirmed?(host, _yes?, _dry_run?) do
    Mix.shell().info(prompt_intro(host))
    confirm(prompt_question())
  end

  @doc false
  def prompt_intro(host) do
    """
    Dstar can add `#{host}` to your hosts file and generate a
    browser-trusted HTTPS certificate with mkcert.
    This lets your browser open `https://#{host}` without certificate errors,
    and enables HTTP/2 so Datastar SSE streams don't hit the 6-connection
    browser limit.
    This may require sudo privileges for `/etc/hosts` and mkcert's local CA
    installation.
    """
  end

  @doc false
  def prompt_question() do
    "Proceed with Dstar HTTPS setup? [Y/n] "
  end

  defp confirm(prompt) do
    case IO.gets(prompt) do
      nil ->
        false

      answer ->
        answer
        |> String.trim()
        |> String.downcase()
        |> case do
          "" ->
            true

          yes when yes in ["y", "yes"] ->
            true

          no when no in ["n", "no"] ->
            false

          _ ->
            Mix.shell().info("Please enter y or n.")
            confirm(prompt)
        end
    end
  end

  defp run_command(command, args, true) do
    Mix.shell().info("Would run: #{format_command(command, args)}")
  end

  defp run_command(command, args, false) do
    command = format_command(command, args)

    case Mix.shell().cmd(command) do
      0 ->
        :ok

      status ->
        Mix.raise("Command failed with status #{status}: #{command}")
    end
  end

  defp run_sudo_command(command, host, ip) do
    if windows?(:os.type()) do
      run_privileged_fallback_command(command, host: host, ip: ip)
    else
      case System.cmd("sudo", sudo_probe_args(command), stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {_output, _status} ->
          run_privileged_fallback_command(command, host: host, ip: ip)
      end
    end
  end

  @doc false
  def sudo_probe_args(command) do
    ["-n", "/bin/sh", "-c", command]
  end

  defp run_privileged_fallback_command(command, opts) do
    case privileged_fallback_command(
           command,
           :os.type(),
           System.find_executable("osascript"),
           opts
         ) do
      {:system, executable, args} ->
        run_system_command(executable, args)

      {:shell, shell_command} ->
        run_shell_command(shell_command)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  def privileged_fallback_command(command, os_type, osascript_executable, opts \\ []) do
    cond do
      macos?(os_type) and is_binary(osascript_executable) ->
        script = "do shell script #{applescript_quote(command)} with administrator privileges"
        {:system, osascript_executable, ["-e", script]}

      windows?(os_type) ->
        {:error, windows_unsupported_message(command, opts)}

      true ->
        {:shell, format_command("sudo", ["-p", "Password: ", "/bin/sh", "-c", command])}
    end
  end

  defp run_system_command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise(
          "Command failed with status #{status}: #{format_command(executable, args)}\n#{output}"
        )
    end
  end

  defp run_shell_command(command) do
    case Mix.shell().cmd(command) do
      0 ->
        :ok

      status ->
        Mix.raise("Command failed with status #{status}: #{command}")
    end
  end

  defp windows_unsupported_message(command, opts) do
    host = Keyword.get(opts, :host, "your-dstar-host.test")
    ip = Keyword.get(opts, :ip, @default_ip)

    """
    Automatic Dstar HTTPS setup is not supported on Windows yet.

    Add this line to your Windows hosts file from an elevated editor or terminal:

        #{ip} #{host}

    Hosts file:

        C:\\Windows\\System32\\drivers\\etc\\hosts

    Then generate the development certificate manually with mkcert. The Unix
    command Dstar would use on macOS/Linux is shown for troubleshooting only:

        #{command}
    """
  end

  defp macos?(os_type) do
    match?({:unix, :darwin}, os_type)
  end

  defp windows?(os_type) do
    match?({:win32, _}, os_type)
  end

  @doc false
  def applescript_quote(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(args, invalid) do
    details =
      []
      |> maybe_add_args_error(args)
      |> maybe_add_invalid_error(invalid)
      |> Enum.join("\n")

    Mix.raise(details)
  end

  defp maybe_add_args_error(errors, []), do: errors

  defp maybe_add_args_error(errors, args) do
    ["Unexpected arguments: #{Enum.join(args, " ")}" | errors]
  end

  defp maybe_add_invalid_error(errors, []), do: errors

  defp maybe_add_invalid_error(errors, invalid) do
    invalid =
      Enum.map_join(invalid, ", ", fn
        {option, nil} -> option
        {option, value} -> "#{option}=#{value}"
      end)

    ["Invalid options: #{invalid}" | errors]
  end

  defp ensure_mkcert!(true), do: :ok

  defp ensure_mkcert!(false) do
    if !System.find_executable("mkcert") do
      Mix.raise("""
      `mkcert` was not found.

      Install it first, then rerun this command:

          brew install mkcert nss
          mix dstar.https
      """)
    end
  end

  defp ensure_certificate_directory!(cert_path, key_path, true) do
    [cert_path, key_path]
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.each(&Mix.shell().info("Would create directory: #{&1}"))
  end

  defp ensure_certificate_directory!(cert_path, key_path, false) do
    [cert_path, key_path]
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.each(&File.mkdir_p!/1)
  end

  defp validate_host!(host) do
    if Regex.match?(
         ~r/^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i,
         host
       ) do
      :ok
    else
      Mix.raise("Invalid DNS hostname for Dstar HTTPS setup: #{inspect(host)}")
    end
  end

  defp validate_ip!(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> Mix.raise("Invalid IP address for Dstar HTTPS setup: #{inspect(ip)}")
    end
  end

  defp strip_hosts_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp format_command(command, args) do
    [command | args]
    |> Enum.map_join(" ", &shell_quote/1)
  end
end
