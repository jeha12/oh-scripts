import unittest

from parse_jtr import Command, build_commands_from_command_line


class CommandNameTests(unittest.TestCase):
    def test_direct_command_name(self):
        cmd = Command(section="s", command="/path/to/c2abc arg1")
        self.assertEqual(cmd.get_command_name(), "c2abc")

    def test_wrapped_bash_command_name(self):
        cmd = Command(
            section="s",
            command="bash -ce /media/bin/ark_aot --flag; /media/bin/ark --run"
        )
        self.assertEqual(cmd.get_command_name(), "ark_aot")

    def test_wrapped_sh_command_name(self):
        cmd = Command(
            section="s",
            command='sh -c "/media/bin/ark --arg"'
        )
        self.assertEqual(cmd.get_command_name(), "ark")

    def test_echo_only_falls_back(self):
        cmd = Command(section="s", command="echo Exit code: $?")
        self.assertEqual(cmd.get_command_name(), "echo")

    def test_only_env_assignment(self):
        cmd = Command(section="s", command="VAR=value")
        self.assertEqual(cmd.get_command_name(), "VAR=value")


class CommandSplitTests(unittest.TestCase):
    def test_split_bash_chain(self):
        command_line = (
            "bash -ce /media/bin/ark_aot --compile file.abc; "
            "/media/bin/ark --run file.abc; echo Exit code: $?"
        )
        commands = build_commands_from_command_line(command_line, "sec", {}, "/tmp")
        names = [cmd.get_command_name() for cmd in commands]
        self.assertEqual(names, ["ark_aot", "ark"])

    def test_split_sh_command(self):
        command_line = 'sh -c "/media/bin/ark --run"'
        commands = build_commands_from_command_line(command_line, "sec", {}, None)
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0].get_command_name(), "ark")

    def test_split_direct_command(self):
        command_line = "/media/bin/c2abc input.abc"
        commands = build_commands_from_command_line(command_line, "sec", {}, None)
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0].get_command_name(), "c2abc")


if __name__ == "__main__":
    unittest.main()
