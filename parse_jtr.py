import re
import subprocess
import sys
import os
import argparse
from typing import List, Dict, Optional, Tuple
import shlex
import json


SHELL_NAMES = {"bash", "sh"}
SHELL_SEPARATORS = {";", "&&", "||"}
ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _tokenize_shell_command(command_str: str) -> List[str]:
    """Tokenize a shell-like command string respecting quotes and separators."""
    if not command_str:
        return []

    lexer = shlex.shlex(command_str, posix=True, punctuation_chars=';&|')
    lexer.whitespace_split = True
    lexer.commenters = ''
    return list(lexer)


def _is_shell_token(token: str) -> bool:
    base = os.path.basename(token)
    return base in SHELL_NAMES


def _is_env_assignment(token: str) -> bool:
    return bool(ENV_ASSIGNMENT_RE.match(token))


def _strip_leading_env(tokens: List[str]) -> List[str]:
    stripped = list(tokens)
    while stripped and _is_env_assignment(stripped[0]):
        stripped.pop(0)
    return stripped


def _strip_shell_wrapper(tokens: List[str]) -> List[str]:
    tokens = list(tokens)
    tokens = _strip_leading_env(tokens)
    if not tokens:
        return []

    if _is_shell_token(tokens[0]):
        tokens = tokens[1:]
        while tokens and tokens[0].startswith('-'):
            tokens.pop(0)
        remainder = ' '.join(tokens).strip()
        if not remainder:
            return []
        return _tokenize_shell_command(remainder)

    return tokens


def _find_real_command_token(tokens: List[str]) -> Optional[str]:
    tokens = _strip_leading_env(tokens)
    if not tokens:
        return None

    if _is_shell_token(tokens[0]):
        return _find_real_command_token(_strip_shell_wrapper(tokens))

    if tokens[0].lower() == 'echo':
        return None

    return tokens[0]


def _expand_wrapped_command(tokens: List[str]) -> List[List[str]]:
    """Expand shell wrappers (bash/sh) and return actual command token lists."""
    remaining = list(tokens)
    env_prefix = []
    while remaining and _is_env_assignment(remaining[0]):
        env_prefix.append(remaining.pop(0))

    if not remaining:
        return []

    if _is_shell_token(remaining[0]):
        remaining.pop(0)
        while remaining and remaining[0].startswith('-'):
            remaining.pop(0)
        remainder = ' '.join(remaining).strip()
        if not remainder:
            return []
        inner_tokens = _tokenize_shell_command(remainder)
        inner_commands = _split_tokens_into_commands(inner_tokens)
        expanded = []
        for inner in inner_commands:
            if inner:
                expanded.append(env_prefix + inner)
        return expanded

    return [env_prefix + remaining]


def _split_tokens_into_commands(tokens: List[str]) -> List[List[str]]:
    commands = []
    current = []
    for token in tokens:
        if token in SHELL_SEPARATORS:
            if current:
                commands.extend(_expand_wrapped_command(current))
                current = []
        else:
            current.append(token)

    if current:
        commands.extend(_expand_wrapped_command(current))

    return [cmd for cmd in commands if cmd]


def _split_command_line(command_line: str) -> List[List[str]]:
    tokens = _tokenize_shell_command(command_line)
    return _split_tokens_into_commands(tokens)


def build_commands_from_command_line(command_line: str, section: str,
                                     env_vars: Dict[str, str],
                                     directory: Optional[str]) -> List['Command']:
    """Split a command line into separate Command objects for each real command."""
    commands = []
    tokenized_commands = _split_command_line(command_line)

    for cmd_tokens in tokenized_commands:
        real_token = _find_real_command_token(cmd_tokens)
        if not real_token:
            continue
        if os.path.basename(real_token).lower() == 'echo':
            continue

        command_text = ' '.join(cmd_tokens).strip()
        commands.append(
            Command(
                section=section,
                command=command_text,
                env_vars=dict(env_vars),
                directory=directory
            )
        )

    return commands


class Command:
    """Class representing a parsed command from test runner output"""
    
    def __init__(self, section: str, command: str, env_vars: Dict[str, str] = None, 
                 directory: str = None):
        self.section = section
        self.command = command
        self.env_vars = env_vars or {}
        self.directory = directory
        self._last_result = None
    
    def execute(self, timeout: int = 300, capture_output: bool = True) -> Tuple[int, str, str]:
        """
        Execute the command and return (return_code, stdout, stderr)
        
        Args:
            timeout: Command timeout in seconds
            capture_output: Whether to capture output or let it go to terminal
        
        Returns:
            Tuple of (return_code, stdout, stderr)
        """
        # Prepare environment
        env = os.environ.copy()
        env.update(self.env_vars)
        
        # Prepare working directory
        cwd = self.directory if self.directory else None
        
        try:
            if capture_output:
                result = subprocess.run(
                    self.command,
                    shell=True,
                    env=env,
                    cwd=cwd,
                    timeout=timeout,
                    capture_output=True,
                    text=True
                )
                self._last_result = (result.returncode, result.stdout, result.stderr)
            else:
                result = subprocess.run(
                    self.command,
                    shell=True,
                    env=env,
                    cwd=cwd,
                    timeout=timeout
                )
                self._last_result = (result.returncode, "", "")
                
        except subprocess.TimeoutExpired:
            error_msg = f"Command timed out after {timeout} seconds"
            self._last_result = (-1, "", error_msg)
        except Exception as e:
            error_msg = f"Command execution failed: {str(e)}"
            self._last_result = (-1, "", error_msg)
        
        return self._last_result
    
    def get_last_result(self) -> Optional[Tuple[int, str, str]]:
        """Get the result of the last execution"""
        return self._last_result
    
    def is_success(self) -> bool:
        """Check if the last execution was successful"""
        return self._last_result is not None and self._last_result[0] == 0
    
    def get_command_name(self) -> str:
        """Extract a representative command name, unwrapping shell helpers."""
        command_str = self.command.strip()
        if not command_str:
            return ""

        tokens = _tokenize_shell_command(command_str)
        real_token = _find_real_command_token(tokens)

        def _format_name(token: str) -> str:
            if '/' in token:
                return token.split('/')[-1]
            return token

        if real_token:
            return _format_name(real_token)

        fallback_parts = command_str.split()
        if not fallback_parts:
            return ""
        return _format_name(fallback_parts[0])
    
    def to_bash_string(self) -> str:
        """Generate bash command string"""
        parts = []
        
        # Add directory change if specified
        if self.directory:
            parts.append(f"cd {self.directory}")
        
        # Add environment variables and command
        env_prefix = ""
        if self.env_vars:
            env_parts = []
            for var, value in self.env_vars.items():
                env_parts.append(f"{var}={value}")
            env_prefix = " ".join(env_parts) + " "
        
        command_line = f"{env_prefix}{self.command}"
        parts.append(command_line)
        
        return " && ".join(parts) if len(parts) > 1 else parts[0]
    
    def __str__(self) -> str:
        cmd_name = self.get_command_name()
        return f"Command(name='{cmd_name}', section='{self.section}', cmd='{self.command[:50]}...', env_vars={len(self.env_vars)}, dir='{self.directory}')"
    
    def __repr__(self) -> str:
        return self.__str__()


class TestRunner:
    """Class for managing parsed test runner commands"""
    
    def __init__(self, commands: List[Command] = None):
        self.commands = commands or []
    
    def add_command(self, command: Command):
        """Add a command to the test runner"""
        self.commands.append(command)
    
    def get_commands(self) -> List[Command]:
        """Get all commands"""
        return self.commands
    
    def get_commands_by_section(self, section_pattern: str) -> List[Command]:
        """Get commands that match a section pattern"""
        import fnmatch
        return [cmd for cmd in self.commands if fnmatch.fnmatch(cmd.section, section_pattern)]
    
    def get_commands_by_name(self, name_pattern: str) -> List[Command]:
        """Get commands that match a command name pattern (e.g., 'ark', 'java')"""
        import fnmatch
        return [cmd for cmd in self.commands if fnmatch.fnmatch(cmd.get_command_name(), name_pattern)]
    
    def get_sections(self) -> List[str]:
        """Get all unique section names"""
        return list(set(cmd.section for cmd in self.commands))
    
    def get_command_names(self) -> List[str]:
        """Get all unique command names"""
        return list(set(cmd.get_command_name() for cmd in self.commands))
    
    def count(self) -> int:
        """Get total number of commands"""
        return len(self.commands)
    
    def execute_all(self, timeout: int = 300, capture_output: bool = True, raw_output: bool = False) -> List[Tuple[Command, int, str, str]]:
        """
        Execute all commands and return results
        
        Returns:
            List of tuples (command, return_code, stdout, stderr)
        """
        def conditional_print_local(*args_print, **kwargs):
            """Print only if not in raw output mode"""
            if not raw_output:
                print(*args_print, **kwargs)
        
        results = []
        conditional_print_local("\n=== Executing All Commands ===")
        
        for i, cmd in enumerate(self.commands, 1):
            conditional_print_local(f"\n{i}. Executing section: {cmd.section}")
            conditional_print_local(f"   Command: {cmd.to_bash_string()}")
            
            return_code, stdout, stderr = cmd.execute(timeout=timeout, capture_output=capture_output)
            results.append((cmd, return_code, stdout, stderr))
            
            # In raw output mode, output is already forwarded, so no need to print results
            if not raw_output:
                if cmd.is_success():
                    conditional_print_local("   ✓ Success")
                else:
                    conditional_print_local(f"   ✗ Failed (return code: {return_code})")
                    if stderr:
                        conditional_print_local(f"   Error: {stderr}")
        
        # Summary
        if not raw_output:
            successful = sum(1 for _, rc, _, _ in results if rc == 0)
            failed = len(results) - successful
            
            conditional_print_local("\n=== Execution Summary ===")
            conditional_print_local(f"Total commands: {len(results)}")
            conditional_print_local(f"Successful: {successful}")
            conditional_print_local(f"Failed: {failed}")
            
            if failed > 0:
                conditional_print_local("\nFailed commands:")
                for cmd, rc, stdout, stderr in results:
                    if rc != 0:
                        conditional_print_local(f"- {cmd.section}: {cmd.command[:50]}... (code: {rc})")
        
        return results
    
    def execute_interactively(self, raw_output: bool = False):
        """Execute commands interactively with user prompts"""
        def conditional_print_local(*args_print, **kwargs):
            """Print only if not in raw output mode"""
            if not raw_output:
                print(*args_print, **kwargs)
        
        conditional_print_local("\n=== Interactive Command Execution ===")
        
        for i, cmd in enumerate(self.commands, 1):
            conditional_print_local(f"\n{i}. Section: {cmd.section}")
            conditional_print_local(f"   Command: {cmd.to_bash_string()}")
            
            while True:
                if raw_output:
                    # In raw output mode, just execute without prompts
                    return_code, stdout, stderr = cmd.execute(capture_output=False)
                    break
                
                choice = input("Execute? (y/n/s/q) [y=yes, n=no, s=show details, q=quit]: ").lower().strip()
                
                if choice == 'q':
                    conditional_print_local("Quitting...")
                    return
                elif choice == 'n':
                    conditional_print_local("Skipped.")
                    break
                elif choice == 's':
                    conditional_print_local(f"   Section: {cmd.section}")
                    conditional_print_local(f"   Command: {cmd.command}")
                    conditional_print_local(f"   Env vars: {cmd.env_vars}")
                    conditional_print_local(f"   Directory: {cmd.directory}")
                    continue
                elif choice in ['y', '']:
                    conditional_print_local("Executing...")
                    return_code, stdout, stderr = cmd.execute()
                    
                    conditional_print_local(f"Return code: {return_code}")
                    if stdout:
                        conditional_print_local("STDOUT:")
                        conditional_print_local(stdout)
                    if stderr:
                        conditional_print_local("STDERR:")
                        conditional_print_local(stderr)
                    
                    if cmd.is_success():
                        conditional_print_local("✓ Command completed successfully")
                    else:
                        conditional_print_local("✗ Command failed")
                    break
                else:
                    conditional_print_local("Invalid choice. Please enter y, n, s, or q.")
    
    def to_bash_script(self) -> str:
        """Generate bash script from all commands"""
        script_lines = ["#!/bin/bash", ""]
        
        for cmd in self.commands:
            script_lines.append(f"# Section: {cmd.section}")
            script_lines.append(cmd.to_bash_string())
            script_lines.append("")  # Empty line for readability
        
        return "\n".join(script_lines)
    
    def print_info(self):
        """Print information about all commands"""
        print("\n=== Parsed Commands ===")
        for i, cmd in enumerate(self.commands, 1):
            print(f"\n{i}. {cmd}")
            print(f"   Bash: {cmd.to_bash_string()}")
        
        print(f"\n=== Summary ===")
        print(f"Total commands: {self.count()}")
        print(f"Sections: {self.get_sections()}")
        print(f"Command names: {self.get_command_names()}")
        
        print(f"\n=== Usage ===")
        print("You can now work with TestRunner and Command objects:")
        print("- runner.execute_all() - Execute all commands")
        print("- runner.execute_interactively() - Execute commands interactively")
        print("- runner.get_commands_by_section('pattern') - Filter commands by section")
        print("- runner.get_commands_by_name('pattern') - Filter commands by name")
        print("- runner.to_bash_script() - Generate bash script")
        print("- cmd.get_command_name() - Get command name (e.g., 'ark')")
        print("- cmd.execute() - Execute individual command")
    
    def __len__(self) -> int:
        return len(self.commands)
    
    def __iter__(self):
        return iter(self.commands)
    
    def __getitem__(self, index):
        return self.commands[index]


def parse_commands(text) -> TestRunner:
    """Parse test runner output and extract all commands as TestRunner object"""
    runner = TestRunner()
    
    # Find all sections
    sections = re.split(r'#section:([^\n]+)', text)
    
    for i in range(1, len(sections), 2):
        section_name = sections[i].strip()
        section_content = sections[i + 1] if i + 1 < len(sections) else ""
        
        if '----------rerun:' in section_content:
            # Parse section with rerun block
            # Handle cases where rerun line has additional info: ----------rerun:(25/7222)*----------
            rerun_match = re.search(r'----------rerun:.*?----------(.*?)----------', section_content, re.DOTALL)
            if rerun_match:
                rerun_content = rerun_match.group(1).strip()
                command = parse_rerun_block(rerun_content, section_name)
                if command:
                    runner.add_command(command)
        
        elif 'Command is:' in section_content:
            # Parse standard format sections
            commands = parse_standard_format(section_content, section_name)
            for command in commands:
                runner.add_command(command)
    
    return runner


def parse_rerun_block(rerun_content, section_name) -> Optional[Command]:
    """Parse rerun block from compile section and return Command object"""
    lines = rerun_content.split('\n')
    env_vars = {}
    cmd_parts = []
    current_dir = None
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # Remove trailing backslashes
        if line.endswith('\\\\'):
            line = line[:-2].strip()
        
        # Check for cd command
        if line.startswith('cd '):
            current_dir = line.split(' ', 1)[1].rstrip(' &&')
        # Check for environment variables (format: VAR=value, but not command arguments)
        elif ('=' in line and not line.startswith('/') and not line.startswith('-') 
              and ' ' not in line.split('=')[0] and not cmd_parts):
            var, value = line.split('=', 1)
            env_vars[var.strip()] = value.strip()
        # Check for command parts
        elif line.startswith('/') or (cmd_parts and not line.startswith('cd')) or (not cmd_parts and not line.startswith('cd') and '=' not in line):
            cmd_parts.append(line)
    
    if cmd_parts:
        command_str = ' '.join(cmd_parts)
        return Command(
            section=section_name,
            command=command_str,
            env_vars=env_vars,
            directory=current_dir
        )
    
    return None


def parse_standard_format(section_content, section_name) -> List[Command]:
    """Parse standard format sections and return Command objects."""
    command_str = None
    env_vars = {}
    directory = None
    command_lines: List[str] = []

    lines = section_content.split('\n')
    i = 0

    while i < len(lines):
        line = lines[i].strip()

        if line.startswith('command:'):
            command_lines.append(line.replace('command:', '', 1).strip())

        if line.startswith('Command is:'):
            command_str = line.replace('Command is:', '').strip()

        elif line == 'Command environment is:':
            # Read environment variables until we hit another section or empty line
            i += 1
            while i < len(lines):
                env_line = lines[i].strip()
                if not env_line or env_line.startswith('Execution directory is:'):
                    break
                if ENV_ASSIGNMENT_RE.match(env_line):
                    var, value = env_line.split('=', 1)
                    env_vars[var.strip()] = value.strip()
                else:
                    break
                i += 1
            i -= 1  # Adjust for the outer loop increment

        elif line.startswith('Execution directory is:'):
            directory = line.replace('Execution directory is:', '').strip()

        i += 1

    commands: List[Command] = []

    if command_str:
        sources = [command_str]
    else:
        sources = command_lines

    for source in sources:
        commands.extend(build_commands_from_command_line(source, section_name, env_vars, directory))

    if not commands and command_str:
        commands.append(
            Command(
                section=section_name,
                command=command_str,
                env_vars=env_vars,
                directory=directory
            )
        )

    return commands


def execute_commands_by_names(runner: TestRunner, command_specs: List[Tuple[str, str]], raw_output: bool = False):
    """Execute specific commands by their names in order"""
    def conditional_print_local(*args_print, **kwargs):
        """Print only if not in raw output mode"""
        if not raw_output:
            print(*args_print, **kwargs)
    
    if not command_specs:
        conditional_print_local("Error: No command names specified for --run option", file=sys.stderr)
        sys.exit(1)
    
    def format_spec(p, a):
        return f'"{p} {a}"'.strip() if a else p
        
    conditional_print_local(f"\n=== Executing Commands by Names ===")
    conditional_print_local(f"Requested commands: {', '.join([format_spec(p, a) for p, a in command_specs])}")
    
    # Find commands for each name (supporting patterns)
    commands_to_execute = []
    for name_pattern, extra_args in command_specs:
        matching_commands = runner.get_commands_by_name(name_pattern)
        if not matching_commands:
            conditional_print_local(f"Warning: No commands found matching pattern '{name_pattern}'")
        else:
            conditional_print_local(f"Pattern '{name_pattern}' matched {len(matching_commands)} command(s):")
            if extra_args:
                conditional_print_local(f"   ... with extra args: '{extra_args}'")
            
            for cmd in matching_commands:
                conditional_print_local(f"   - {cmd.get_command_name()} ({cmd.section})")
                
                if extra_args:
                    cmd_parts = cmd.command.strip().split(maxsplit=1)
                    executable = cmd_parts[0]
                    original_args = cmd_parts[1] if len(cmd_parts) > 1 else ""
                    
                    # Safely split and quote user-provided arguments
                    safe_extra_args_list = [shlex.quote(arg) for arg in shlex.split(extra_args)]
                    safe_extra_args = " ".join(safe_extra_args_list)
                    
                    new_command_str = f"{executable} {safe_extra_args} {original_args}".strip()
                    
                    exec_cmd = Command(
                        section=cmd.section,
                        command=new_command_str,
                        env_vars=cmd.env_vars,
                        directory=cmd.directory
                    )
                    commands_to_execute.append(exec_cmd)
                else:
                    commands_to_execute.append(cmd)
    
    if not commands_to_execute:
        conditional_print_local("No commands to execute", file=sys.stderr)
        sys.exit(1)
    
    conditional_print_local(f"\nExecuting {len(commands_to_execute)} command(s) in order...")
    
    # Execute commands in order
    results = []
    for i, cmd in enumerate(commands_to_execute, 1):
        conditional_print_local(f"\n{i}. Executing: {cmd.get_command_name()} (section: {cmd.section})")
        conditional_print_local(f"   Command: {cmd.to_bash_string()}")
        
        return_code, stdout, stderr = cmd.execute(capture_output=not raw_output)
        results.append((cmd, return_code, stdout, stderr))
        
        # In raw output mode, output is already forwarded, so no need to print results
        if not raw_output:
            if cmd.is_success():
                conditional_print_local("   ✓ Success")
            else:
                conditional_print_local(f"   ✗ Failed (return code: {return_code})")
                if stderr:
                    conditional_print_local(f"   Error: {stderr}")
    
    # Summary
    if not raw_output:
        successful = sum(1 for _, rc, _, _ in results if rc == 0)
        failed = len(results) - successful
        
        conditional_print_local("\n=== Execution Summary ===")
        conditional_print_local(f"Total executed: {len(results)}")
        conditional_print_local(f"Successful: {successful}")
        conditional_print_local(f"Failed: {failed}")
        
        if failed > 0:
            conditional_print_local("\nFailed commands:")
            for cmd, rc, stdout, stderr in results:
                if rc != 0:
                    conditional_print_local(f"- {cmd.get_command_name()} ({cmd.section}): code {rc}")


def parse_run_specs(run_specs_list: List[str]) -> List[Tuple[str, str]]:
    """Parse a list of run spec strings into (name_pattern, extra_args) tuples."""
    command_specs = []
    for spec in run_specs_list:
        parts = spec.strip().split(maxsplit=1)
        name_pattern = parts[0]
        extra_args = parts[1] if len(parts) > 1 else ""
        command_specs.append((name_pattern, extra_args))
    return command_specs


def print_debug_config(runner: TestRunner, name_pattern: str, extra_args: str):
    """
    Finds a command and prints a launch.json-style debug configuration.
    """
    matching_commands = runner.get_commands_by_name(name_pattern)

    if not matching_commands:
        print(f"Error: No command found matching pattern '{name_pattern}'", file=sys.stderr)
        sys.exit(1)

    if len(matching_commands) > 1:
        print(f"Warning: Found {len(matching_commands)} commands matching pattern '{name_pattern}'. Using the first one.", file=sys.stderr)

    command_to_debug = matching_commands[0]
    
    # Prepare extra args
    safe_extra_args_list = []
    if extra_args:
        safe_extra_args_list = shlex.split(extra_args)
        
    # Prepare original command and args
    command_parts = shlex.split(command_to_debug.command)
    program = command_parts[0]
    original_args = command_parts[1:]
    
    final_args = safe_extra_args_list + original_args

    # Create the launch config dictionary
    launch_config = {
        "type": "lldb",
        "request": "launch",
        "name": f"Debug {command_to_debug.get_command_name()}",
        "program": program,
        "args": final_args,
        "cwd": command_to_debug.directory or os.getcwd(),
        "env": command_to_debug.env_vars
    }

    # Print the config as a pretty-printed JSON
    print(json.dumps(launch_config, indent=4))


def main():
    """Main function to parse and work with Command objects"""
    
    parser = argparse.ArgumentParser(
        description='Parse test runner output and work with Command objects.',
        epilog='''Examples:
  %(prog)s                              # Parse and show Command objects
  %(prog)s --bash                       # Generate bash script
  %(prog)s test_output.txt --execute    # Parse file and execute interactively
  %(prog)s --execute-all                # Execute all commands automatically
  %(prog)s --run ark aot_cmd              # Execute 'ark' then 'aot_cmd' commands
  %(prog)s --run "*compile*"              # Execute all commands matching '*compile*'
  %(prog)s --run "ark --verbose"          # Execute 'ark' with '--verbose' argument
  %(prog)s --run "ark -v" "aot_cmd --debug" # Execute 'ark' with '-v' and 'aot_cmd' with '--debug'
  %(prog)s --raw-output --run ark         # Execute 'ark' with clean output (safer order)
  %(prog)s --run "ark [-b=A,B]" --run-arg-cycle # Cycles through 'ark -b=A' and 'ark -b=B' for execution
  %(prog)s --run "ark [-b=A,B]" --run-arg-seq   # Runs 'ark -b=A' then 'ark -b=A,B'
  %(prog)s --print-debug-cfg "ark --my-arg"   # Prints a debug configuration for the 'ark' command
        ''',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('input_file', nargs='?', 
                       help='Optional input file with test runner output. '
                            'If not provided, uses the built-in output variable.')
    
    # Mode selection (mutually exclusive)
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument('--bash', action='store_true',
                           help='Generate and print bash script (legacy mode)')
    mode_group.add_argument('--execute', action='store_true',
                           help='Execute commands interactively')
    mode_group.add_argument('--execute-all', action='store_true',
                           help='Execute all commands automatically')
    mode_group.add_argument('--run', nargs='+', metavar='"cmd [args...]"',
                           help='Execute specific commands by name, with optional custom arguments. '
                                'Each command and its arguments should be a single quoted string. '
                                'Supports patterns like "*compile*".')
    
    parser.add_argument('--raw-output', action='store_true',
                       help='Suppress all script messages and forward stdout/stderr '
                            'from executed commands directly to script output streams')
    
    parser.add_argument('--run-arg-cycle', action='store_true',
                           help='Enable cycling through comma-separated arguments in square brackets for --run. '
                                'Example: --run "cmd [arg1,arg2]" --run-arg-cycle')
    
    parser.add_argument('--run-arg-seq', action='store_true',
                        help='Enable sequential accumulation of comma-separated arguments in square brackets for --run. '
                             'Example: --run "cmd [arg1,arg2]" --run-arg-seq')
    
    mode_group.add_argument('--print-debug-cfg', metavar='"cmd [args...]"',
                           help='Print a launch.json-style debug configuration for a command.')
    
    args = parser.parse_args()
    
    # Determine mode
    if args.bash:
        mode = 'bash'
    elif args.execute:
        mode = 'execute'
    elif args.execute_all:
        mode = 'execute_all'
    elif args.run:
        mode = 'run'
    elif args.print_debug_cfg:
        mode = 'print_debug_cfg'
    else:
        mode = 'info'
    
    input_file = args.input_file
    raw_output = args.raw_output
    
    def conditional_print(*args_print, **kwargs):
        """Print only if not in raw output mode"""
        if not raw_output:
            print(*args_print, **kwargs)
    
    # Determine input source
    if input_file:
        try:
            with open(input_file, 'r', encoding='utf-8') as f:
                text_to_parse = f.read()
            conditional_print(f"# Parsed from file: {input_file}", file=sys.stderr)
        except FileNotFoundError:
            conditional_print(f"Error: File '{input_file}' not found", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            conditional_print(f"Error reading file '{input_file}': {e}", file=sys.stderr)
            sys.exit(1)
    else:
        # Use the output variable
        text_to_parse = output
        conditional_print("# Parsed from built-in output variable", file=sys.stderr)
    
    # Parse commands
    runner = parse_commands(text_to_parse)
    
    if not runner.count():
        conditional_print("No commands found in the output", file=sys.stderr)
        sys.exit(1)
    
    conditional_print(f"# Found {runner.count()} command(s)", file=sys.stderr)
    
    # Handle --print-debug-cfg first as it's a simple exit mode
    if mode == 'print_debug_cfg':
        spec = args.print_debug_cfg
        parts = spec.strip().split(maxsplit=1)
        name_pattern = parts[0]
        extra_args = parts[1] if len(parts) > 1 else ""
        print_debug_config(runner, name_pattern, extra_args)
        sys.exit(0)
    
    # Handle --run-arg-cycle and --run-arg-seq logic
    if mode == 'run' and (args.run_arg_cycle or args.run_arg_seq):
        if args.run_arg_cycle and args.run_arg_seq:
            conditional_print("Error: --run-arg-cycle and --run-arg-seq cannot be used together.", file=sys.stderr)
            sys.exit(1)

        # Find the command spec with the cycle syntax [...]
        spec_to_process_index = -1
        cycle_prefix, cycle_values_str, cycle_suffix = None, None, None

        for i, spec in enumerate(args.run): # args.run contains the list of strings
            match = re.search(r"^(.*)\[(.+?)\](.*)$", spec)
            if match:
                if spec_to_process_index != -1:
                    conditional_print("Error: Multiple command specs with [...] syntax found. Only one is supported.", file=sys.stderr)
                    sys.exit(1)
                
                spec_to_process_index = i
                cycle_prefix, cycle_values_str, cycle_suffix = match.groups()
        
        if spec_to_process_index != -1:
            values = [v.strip() for v in cycle_values_str.split(',')]
            base_run_specs_list = args.run

            total_variants = len(values)
            run_type_str = "Cycling" if args.run_arg_cycle else "Sequencing"
            conditional_print(f"\n{run_type_str} through {total_variants} argument variants...")

            for i in range(total_variants):
                conditional_print(f"\n--- Variant {i+1}/{total_variants} ---")
                
                if args.run_arg_cycle:
                    current_values_str = values[i]
                else: # --run-arg-seq
                    current_values_str = ",".join(values[:i+1])
                
                new_spec_string = f"{cycle_prefix}{current_values_str}{cycle_suffix}"
                
                current_run_specs_list = list(base_run_specs_list)
                current_run_specs_list[spec_to_process_index] = new_spec_string
                
                command_specs = parse_run_specs(current_run_specs_list)
                execute_commands_by_names(runner, command_specs, raw_output=raw_output)

            sys.exit(0) # We are done
        else:
            flag_name = "--run-arg-cycle" if args.run_arg_cycle else "--run-arg-seq"
            conditional_print(f"Warning: {flag_name} was specified, but no [...] syntax was found in any --run argument. Proceeding with normal execution.", file=sys.stderr)
    
    # Handle different modes
    if mode == 'bash':
        # Legacy mode - generate bash script
        bash_script = runner.to_bash_script()
        print(bash_script)
    
    elif mode == 'info':
        # Show TestRunner and Command objects info
        if not raw_output:
            runner.print_info()
    
    elif mode == 'execute':
        # Interactive execution
        runner.execute_interactively(raw_output=raw_output)
    
    elif mode == 'execute_all':
        # Execute all commands automatically
        runner.execute_all(capture_output=not raw_output, raw_output=raw_output)
    
    elif mode == 'run':
        # Execute specific commands by name in order
        command_specs = parse_run_specs(args.run)
        execute_commands_by_names(runner, command_specs, raw_output=raw_output)


if __name__ == "__main__":
    main()
