defmodule Mix.Tasks.Dstar.HttpsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Dstar.Https

  setup do
    on_exit(fn ->
      Application.delete_env(:dstar_demo, :dstar)
    end)
  end

  test "hyphenates fallback host from app name" do
    assert Https.dev_host(:dstar_demo) == "dstar-demo.test"
  end

  test "reads host from app-specific Dstar dev URL" do
    Application.put_env(:dstar_demo, :dstar, dev_url: "https://demo.test:4001")

    assert Https.configured_host(:dstar_demo) == "demo.test"
  end

  test "returns nil when no dev URL is configured" do
    assert Https.configured_host(:dstar_demo) == nil
  end

  test "finds hosts entries while ignoring comments" do
    contents = """
    127.0.0.1 localhost
    # 127.0.0.1 ignored.test
    127.0.0.1 demo.test alias.test # comment
    """

    assert Https.hosts_entry_ip(contents, "demo.test") == "127.0.0.1"
    assert Https.hosts_entry_ips(contents, "demo.test") == ["127.0.0.1"]
    assert Https.hosts_entry_ip(contents, "alias.test") == "127.0.0.1"
    assert Https.hosts_entry_ip(contents, "ignored.test") == nil
  end

  test "finds all duplicate hosts entries" do
    contents = """
    127.0.0.1 demo.test
    127.0.0.2 demo.test
    """

    assert Https.hosts_entry_ip(contents, "demo.test") == "127.0.0.1"
    assert Https.hosts_entry_ips(contents, "demo.test") == ["127.0.0.1", "127.0.0.2"]
  end

  test "builds hosts append command with shell quoting" do
    assert Https.hosts_append_command("demo.test", "127.0.0.1", "/tmp/hosts") ==
             "printf '\\n%s\\n' '127.0.0.1 demo.test' >> '/tmp/hosts'"
  end

  test "builds mkcert certificate command args" do
    assert Https.mkcert_certificate_args(
             "demo.test",
             "/tmp/selfsigned.pem",
             "/tmp/selfsigned_key.pem"
           ) == [
             "-cert-file",
             "/tmp/selfsigned.pem",
             "-key-file",
             "/tmp/selfsigned_key.pem",
             "demo.test",
             "localhost",
             "127.0.0.1",
             "::1"
           ]
  end

  test "keeps the interactive options on the final prompt line" do
    assert Https.prompt_intro("demo.test") =~
             "browser-trusted HTTPS certificate with mkcert"

    assert Https.prompt_question() == "Proceed with Dstar HTTPS setup? [Y/n] "
  end

  test "run/1 raises before mkcert install when the host already points at a different IP" do
    hosts_file =
      Path.join(System.tmp_dir!(), "dstar_https_#{System.unique_integer([:positive])}")

    File.write!(hosts_file, "127.0.0.2 demo.test\n")
    on_exit(fn -> File.rm(hosts_file) end)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/demo.test already exists .* with IP 127.0.0.2/s, fn ->
          Https.run(["--yes", "--dry-run", "--host", "demo.test", "--hosts-file", hosts_file])
        end
      end)

    refute output =~ "mkcert"
  end

  test "run/1 raises when any duplicate host entry has a conflicting IP" do
    hosts_file =
      Path.join(System.tmp_dir!(), "dstar_https_#{System.unique_integer([:positive])}")

    File.write!(hosts_file, "127.0.0.1 demo.test\n127.0.0.2 demo.test\n")
    on_exit(fn -> File.rm(hosts_file) end)

    assert_raise Mix.Error, ~r/demo.test already exists .*127.0.0.1, 127.0.0.2/s, fn ->
      Https.run(["--yes", "--dry-run", "--host", "demo.test", "--hosts-file", hosts_file])
    end
  end

  describe "privileged command selection" do
    test "sudo_probe_args/1 probes cached sudo without prompting" do
      assert Https.sudo_probe_args("echo ok") == ["-n", "/bin/sh", "-c", "echo ok"]
    end

    test "macOS fallback uses osascript administrator privileges when available" do
      assert {:system, "/usr/bin/osascript", ["-e", script]} =
               Https.privileged_fallback_command(
                 "printf \"hello\" >> /etc/hosts",
                 {:unix, :darwin},
                 "/usr/bin/osascript"
               )

      assert script ==
               ~s(do shell script "printf \\"hello\\" >> /etc/hosts" with administrator privileges)
    end

    test "macOS fallback uses sudo when osascript is unavailable" do
      assert {:shell, command} =
               Https.privileged_fallback_command("echo ok", {:unix, :darwin}, nil)

      assert command == "'sudo' '-p' 'Password: ' '/bin/sh' '-c' 'echo ok'"
    end

    test "Linux fallback uses interactive sudo" do
      assert {:shell, command} =
               Https.privileged_fallback_command("echo ok", {:unix, :linux}, nil)

      assert command == "'sudo' '-p' 'Password: ' '/bin/sh' '-c' 'echo ok'"
    end

    test "Windows returns a clear unsupported message with native hosts-file guidance" do
      assert {:error, message} =
               Https.privileged_fallback_command("echo ok", {:win32, :nt}, nil,
                 host: "demo.test",
                 ip: "127.0.0.1"
               )

      assert message =~ "not supported on Windows"
      assert message =~ "127.0.0.1 demo.test"
      assert message =~ "C:\\Windows\\System32\\drivers\\etc\\hosts"
      assert message =~ "troubleshooting only"
      assert message =~ "echo ok"
    end
  end

  test "applescript_quote/1 escapes quotes and backslashes" do
    assert Https.applescript_quote(~s|echo "C:\\tmp"|) == ~s|"echo \\\"C:\\\\tmp\\\""|
  end
end
