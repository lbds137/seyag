"""Executing-span survival suite for plugins/seyag/hooks/lib/shell_quotes.py.

The wrapper-bypass class lives at the scanner layer, one above branch_switch:
the quote and heredoc strippers erase data (correctly), and every span bash
EXECUTES is only visible to a guard because a second reader puts it back. Each
family below pins that second reader for one way a command can hide an
executing span from a stripped view:

  * HeredocToShell       a heredoc fed to a shell (`bash <<'EOF'`, `<<EOF`,
                         `cat <<EOF | sh`): bash runs the body whatever the
                         delimiter quoting, so both delimiter forms must
                         surface the body's commands
  * RuntimeConstruction  `$(...)` and backtick spans, quoted or not
  * HereStrings          `bash <<< "..."` and `echo "..." | bash`
  * EvalJoinedTails      `eval` joining its words into one command line, and
                         the `-c` wrappers of the five shells

A vector is behavioural: a command goes in, and the assertion is about what
the scanner hands a walk (a simple command at an executing position, a
wrapper string, a substitution span the walk's predicate can see). The strip
mechanics themselves are pinned by tests/shell_quotes_cases.py; this suite is
the survival angle on top: the same strip that erases an inert span must not
take an executing one with it. Every family carries controls (the same shape
with the span inert) so a survival assertion cannot pass vacuously.

Run:
    cd tests && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scanner_parity_test -v

tests/scanner-parity.probe.sh runs this in the probe suite. Commands use
invented names only; nothing here executes any of them.
"""

import os
import sys
import unittest

# The lib under test lives one directory up and back down into the plugin.
LIB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "plugins", "seyag", "hooks", "lib")
sys.path.insert(0, LIB_DIR)

from shell_quotes import (  # noqa: E402
    simple_commands,
    strip_heredoc_bodies,
    strip_quoted_indexed,
    substitution_spans_matching,
    wrapped_command_strings,
)

SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
COMMIT = ["git", "commit", "-m", "x"]
CD = ["cd", "/other"]


def runs(command, argv):
    """True when `argv` is the start of a simple command bash would execute
    from `command` (the scanner's `simple_commands` reading)."""
    return any(got[: len(argv)] == argv for got in simple_commands(command))


def runs_before(command, first, second):
    """True when both argv are executed and `first` is read before `second`."""
    seen = simple_commands(command)
    firsts = [i for i, got in enumerate(seen) if got[: len(first)] == first]
    seconds = [i for i, got in enumerate(seen) if got[: len(second)] == second]
    return bool(firsts) and bool(seconds) and firsts[0] < seconds[0]


def span_mentions(command, needle):
    """The walk's own substitution reading: True when a `$(...)` or backtick
    span of `command`, cleaned as bash sees it, names `needle`."""
    return substitution_spans_matching(command, lambda span: needle in span)


class ParityCase(unittest.TestCase):
    def check_runs(self, label, command, argv=COMMIT):
        with self.subTest(label, command=command):
            self.assertTrue(runs(command, argv), f"{argv} not surfaced from {command!r}: {simple_commands(command)}")

    def check_inert(self, label, command, argv=COMMIT):
        with self.subTest(label, command=command):
            self.assertFalse(runs(command, argv), f"{argv} surfaced from inert {command!r}")


class HeredocToShell(ParityCase):
    """A heredoc body is data to every program except a shell reading stdin."""

    OPENERS = ("<<'EOF'", '<<"EOF"', "<<EOF", "<<-EOF")

    def test_both_delimiter_forms_surface_for_every_shell(self):
        for shell in SHELLS:
            for opener in self.OPENERS:
                command = f"{shell} {opener}\ngit commit -m x\nEOF"
                self.check_runs(f"{shell} fed {opener}", command)

    def test_indented_body_of_a_dash_heredoc_surfaces(self):
        self.check_runs("<<- body, tab indented", "bash <<-EOF\n\tgit commit -m x\n\tEOF")

    def test_position_survives_behind_a_cd(self):
        for shell in SHELLS:
            for opener in ("<<'EOF'", "<<EOF"):
                command = f"cd /other && {shell} {opener}\ngit commit -m x\nEOF"
                with self.subTest(f"{shell} fed {opener} after a cd", command=command):
                    self.assertTrue(runs_before(command, CD, COMMIT), simple_commands(command))

    def test_pipe_fed_shell_surfaces(self):
        for shell in SHELLS:
            for opener in ("<<'EOF'", "<<EOF"):
                command = f"cat {opener} | {shell}\ngit commit -m x\nEOF"
                self.check_runs(f"cat {opener} piped to {shell}", command)

    def test_runner_prefixed_shell_surfaces(self):
        for prefix in ("sudo ", "timeout 5 ", "env -i ", "FOO=1 ", "/bin/"):
            for opener in ("<<'EOF'", "<<EOF"):
                command = f"{prefix}bash {opener}\ngit commit -m x\nEOF"
                self.check_runs(f"{prefix!r} bash fed {opener}", command)

    def test_shell_with_stdin_flag_surfaces(self):
        self.check_runs("bash -s <<EOF", "bash -s <<EOF\ngit commit -m x\nEOF")
        self.check_runs("sh -s <<'EOF'", "sh -s <<'EOF'\ngit commit -m x\nEOF")

    def test_two_openers_on_one_shell_both_surface(self):
        command = "bash <<'A' <<'B'\ngit commit -m one\nA\ngit commit -m two\nB"
        self.check_runs("first body", command, ["git", "commit", "-m", "one"])
        self.check_runs("second body", command, ["git", "commit", "-m", "two"])

    def test_data_heredoc_beside_a_shell_heredoc_does_not_hide_it(self):
        command = "cat <<'DATA' >/dev/null; bash <<'RUN'\nnotes\nDATA\ngit commit -m x\nRUN"
        self.check_runs("shell body next to a data body", command)

    def test_shell_heredoc_after_other_commands_surfaces(self):
        command = "git status && cd /other && bash <<'EOF'\ngit add a\ngit commit -m x\nEOF"
        self.check_runs("add in the body", command, ["git", "add", "a"])
        self.check_runs("commit in the body", command)

    def test_the_walk_strip_still_erases_the_body(self):
        # The stripped view the walk reads has no body, which is exactly why the
        # survival above is asserted on the executing-position reading and why
        # branch_switch carries its own compensating entry for this family.
        for shell in SHELLS:
            for opener in self.OPENERS:
                command = f"cd /other && {shell} {opener}\ngit commit -m x\nEOF"
                with self.subTest(f"{shell} fed {opener}"):
                    self.assertNotIn("git commit", strip_heredoc_bodies(command))

    def test_controls_a_heredoc_none_of_the_five_stdin_shells_executes_stays_data(self):
        # Pins today's scanner boundary: only the five stdin shells it models
        # (`SHELLS`) turn a heredoc body into commands. That is not the same as
        # "nobody executes it": `python3 -` runs its heredoc body as Python, and
        # a Python body that shells out would run `git commit`; the scanner
        # reads it as data, so the `python3 -` control records the boundary
        # rather than a claim about bash.
        self.check_inert("cat", "cat <<'EOF'\ngit commit -m x\nEOF")
        self.check_inert("cat unquoted", "cat <<EOF\ngit commit -m x\nEOF")
        self.check_inert("python3 - (not a stdin shell the scanner models)", "python3 - <<'EOF'\ngit commit -m x\nEOF")
        self.check_inert("a commit message body", "git commit -F - <<'EOF'\ngit commit -m x\nEOF")
        self.check_inert("tee", "tee notes.txt <<EOF\ngit commit -m x\nEOF")

    def test_controls_the_opener_line_itself_survives(self):
        self.check_runs("the message commit", "git commit -F - <<'EOF'\nmsg\nEOF", ["git", "commit", "-F", "-"])

    def test_quoted_shell_word_body_surfaces(self):
        # Review F3 predicted a gap here and it does not exist: bash strips the
        # quotes off a command word ("bash" runs bash), the scanner resolves
        # the word's content when it forms simple commands, and the body
        # surfaces exactly like the bare word's — simple_commands reads
        # ['bash', '<<EOF'] here and keeps the body via the stdin-shell rule.
        # Pinning the correct behaviour.
        command = "cd /other && git commit -m a && \"bash\" <<'EOF'\ncd /else\ngit commit -m b\nEOF"
        self.assertTrue(runs(command, ["git", "commit", "-m", "b"]), simple_commands(command))


class RuntimeConstruction(ParityCase):
    """`$(...)` and backtick spans run at expansion time, quoted or not."""

    def test_unquoted_substitution_surfaces_in_every_position(self):
        self.check_runs("command position", "$(git commit -m x)")
        self.check_runs("argument", "echo $(git commit -m x)")
        self.check_runs("assignment", "out=$(git commit -m x)")
        self.check_runs("behind a cd inside the span", "echo $(cd /other && git commit -m x)")
        with self.subTest("cd then commit order inside the span"):
            self.assertTrue(runs_before("out=$(cd /other && git commit -m x)", CD, COMMIT))

    def test_quoted_substitution_is_visible_to_the_walk_predicate(self):
        for label, command in (
            ("double-quoted", 'echo "$(git commit -m x)"'),
            ("double-quoted assignment", 'out="$(git commit -m x)"'),
            ("double-quoted in an argument", 'git log --grep "$(git commit -m x)"'),
            ("unquoted", "echo $(git commit -m x)"),
        ):
            with self.subTest(label, command=command):
                self.assertTrue(span_mentions(command, "git commit"))

    def test_backtick_spans_are_visible_to_the_walk_predicate(self):
        for label, command in (
            ("command position", "`git commit -m x`"),
            ("argument", "echo `git commit -m x`"),
            ("assignment", "out=`git commit -m x`"),
            ("inside double quotes", 'echo "`git commit -m x`"'),
        ):
            with self.subTest(label, command=command):
                self.assertTrue(span_mentions(command, "git commit"))

    def test_later_lines_of_a_backtick_span_surface(self):
        self.check_runs("second line of a span", "out=`cd /other\ngit commit -m x`")
        self.check_runs("second line, more commands", "echo `true\ngit add a\ngit commit -m x`", COMMIT)

    def test_runtime_built_verb_is_visible_to_the_walk_predicate(self):
        self.assertTrue(span_mentions("git $(echo commit) -m x", "commit"))
        self.assertTrue(span_mentions("git `echo commit` -m x", "commit"))
        self.assertTrue(span_mentions('$(echo git) commit -m x', "echo git"))

    def test_nested_substitution_is_visible_to_the_walk_predicate(self):
        self.assertTrue(span_mentions("echo $(echo $(git commit -m x))", "git commit"))
        self.assertTrue(span_mentions("echo $(echo `git commit -m x`)", "git commit"))
        self.assertTrue(span_mentions('echo "$(echo $(git commit -m x))"', "git commit"))

    def test_heredoc_body_of_an_executed_span_surfaces(self):
        # A span whose output bash runs turns its heredoc body from data into
        # code; a captured or argument span keeps it data.
        body = "cat <<'EOF'\ngit commit -m x\nEOF\n"
        self.check_runs("bare span", f"$({body})")
        self.check_runs("eval of a span", f'eval "$({body})"')
        self.check_runs("bash -c of a span", f'bash -c "$({body})"')
        self.check_runs("backtick at command position", f"`{body}`")

    def test_substitution_feeding_eval_is_visible_to_the_walk_predicate(self):
        self.assertTrue(span_mentions('eval "$(echo git commit -m x)"', "git commit"))
        self.assertTrue(span_mentions('bash -c "$(printf git\\ commit)"', "commit"))

    def test_controls_inert_spans_stay_inert(self):
        for label, command in (
            ("single-quoted substitution", "echo '$(git commit -m x)'"),
            ("single-quoted backticks", "echo '`git commit -m x`'"),
            ("quoted prose inside a span", 'echo $(gh pr comment --body "run git commit later")'),
            ("heredoc data holding a span", "cat <<'EOF'\n$(git commit -m x)\nEOF"),
            ("no span at all", "git status"),
        ):
            with self.subTest(label, command=command):
                self.assertFalse(span_mentions(command, "git commit"))

    def test_controls_captured_and_argument_span_bodies_stay_data(self):
        body = "cat <<'EOF'\ngit commit -m x\nEOF\n"
        self.check_inert("captured span", f"out=$({body})")
        self.check_inert("argument span", f'echo "$({body})"')

    @unittest.expectedFailure
    def test_known_gap_unquoted_heredoc_body_substitution(self):
        # KNOWN GAP, recorded rather than hidden: bash expands `$(...)` in the
        # body of an UNQUOTED-delimiter heredoc, so this commit runs, but the
        # strip treats every heredoc body as data (shell_quotes.py documents
        # it as an accepted under-arm on `strip_heredoc_bodies`). The vector
        # states the behaviour the walk wants; it is an expected failure so
        # the suite reddens ("unexpected success") the day the scanner closes
        # the gap and this marker must come off. Reported with this suite.
        command = "cat <<EOF\n$(git commit -m x)\nEOF"
        self.assertTrue(span_mentions(command, "git commit") or runs(command, COMMIT))

    def _nested_span_surfaced(self, command):
        return (
            span_mentions(command, "git commit")
            or runs(command, COMMIT)
            or any("git commit" in inner for inner in wrapped_command_strings(command))
        )

    @unittest.expectedFailure
    def test_known_gap_quoted_substitution_nested_in_an_unquoted_span(self):
        # KNOWN GAP, recorded rather than hidden: `substitution_spans_matching`
        # cleans each outermost span with `strip_quoted`, which erases a quoted
        # argument of the span, so a `$(...)` nested in quotes inside a span is
        # surfaced by none of the readers. Expected failure, same contract as
        # above; branch_switch compensates for the walk with
        # `_substitution_hides_execution` (pinned in branch_switch_test.py).
        self.assertTrue(self._nested_span_surfaced('echo $(echo "$(git commit -m x)")'))

    def test_quoted_substitution_nested_in_a_quoted_span_surfaces(self):
        # Control for the gaps below: when the outer span is itself quoted the
        # quote-aware command reader descends into it and reads the nested
        # span's commands, though the walk's span predicate does not (it
        # cleans the outer span first).
        command = 'echo "$(echo "$(git commit -m x)")"'
        self.check_runs("nested quoted spans", command)
        with self.subTest("the walk predicate misses it", command=command):
            self.assertFalse(span_mentions(command, "git commit"))

    @unittest.expectedFailure
    def test_known_gap_wrapper_inside_a_quoted_span(self):
        # Same gap for a wrapper: the enclosing quotes hide `bash -c` from the
        # top-level wrapper reader, and the span clean then erases its string.
        self.assertTrue(self._nested_span_surfaced("echo \"$(bash -c 'git commit -m x')\""))


class HereStrings(ParityCase):
    """A here-string is the stdin script of a shell, not data."""

    def test_here_string_to_every_shell_surfaces(self):
        for shell in SHELLS:
            for form in (
                f'{shell} <<< "git commit -m x"',
                f"{shell} <<< 'git commit -m x'",
                f'{shell} <<<"git commit -m x"',
                f"{shell} <<<'git commit -m x'",
                f"{shell} -s <<< 'git commit -m x'",
            ):
                self.check_runs(f"{shell}: {form}", form)
                with self.subTest(f"{shell} wrapped string: {form}"):
                    self.assertEqual(wrapped_command_strings(form), ["git commit -m x"])

    def test_here_string_position_survives_behind_a_cd(self):
        command = 'cd /other && bash <<< "git commit -m x"'
        with self.subTest(command=command):
            self.assertTrue(runs_before(command, CD, COMMIT))

    def test_here_string_with_a_chain_surfaces_every_command(self):
        command = "sh <<< 'cd /other && git add a && git commit -m x'"
        self.check_runs("add", command, ["git", "add", "a"])
        self.check_runs("commit", command)
        with self.subTest("cd then commit order"):
            self.assertTrue(runs_before(command, CD, COMMIT))

    def test_echo_and_printf_piped_into_a_shell_surface(self):
        for form in (
            'echo "git commit -m x" | bash',
            "echo 'git commit -m x' | sh",
            "echo -e 'git commit -m x' | zsh",
            "printf 'git commit -m x' | dash",
            'echo "git commit -m x" | sudo bash',
        ):
            self.check_runs(form, form)

    def test_substitution_inside_a_here_string_is_visible_to_the_walk_predicate(self):
        self.assertTrue(span_mentions('bash <<< "$(git commit -m x)"', "git commit"))

    def test_controls_a_here_string_to_a_non_shell_stays_data(self):
        self.check_inert("cat", 'cat <<< "git commit -m x"')
        self.check_inert("grep", "grep -c 'git commit' <<< 'git commit -m x'")
        self.check_inert("read", 'read -r line <<< "git commit -m x"')
        self.check_inert("echo not piped to a shell", 'echo "git commit -m x"')
        self.check_inert("echo piped to a non-shell", 'echo "git commit -m x" | wc -c')
        self.check_inert("printf into cat", "printf 'git commit -m x' | cat")


class EvalJoinedTails(ParityCase):
    """`eval` and the shells' `-c` take words and run them as one command line."""

    def test_eval_joined_tail_surfaces(self):
        self.check_runs("bare words", "eval git commit -m x")
        self.check_runs("quoted words", "eval 'git' 'commit' -m x")
        self.check_runs("quoted head, bare tail", "eval 'git commit' -m x")
        self.check_runs("assignment prefix", "FOO=1 eval git commit -m x")
        self.check_runs("runner prefix", "command eval git commit -m x")

    def test_eval_wrapped_string_is_the_joined_words(self):
        for command, joined in (
            ("eval git commit -m x", "git commit -m x"),
            ("eval 'git' 'commit' -m x", "git commit -m x"),
            ("eval 'cd /other &&' git commit -m x", "cd /other && git commit -m x"),
            ("eval cd /other '&&' git commit -m x", "cd /other && git commit -m x"),
        ):
            with self.subTest(command=command):
                self.assertEqual(wrapped_command_strings(command), [joined])

    def test_eval_tail_joined_across_an_and_surfaces_in_order(self):
        for command in (
            "eval 'cd /other &&' git commit -m x",
            "eval cd /other '&&' git commit -m x",
            "cd /other && eval git commit -m x",
        ):
            with self.subTest(command=command):
                self.assertTrue(runs_before(command, CD, COMMIT), simple_commands(command))

    def test_nested_eval_surfaces_within_the_depth_bound(self):
        self.check_runs("two levels", "eval \"eval 'git commit -m x'\"")
        self.check_runs("three levels", "eval \"eval 'eval git commit -m x'\"")

    def test_c_wrapper_of_every_shell_surfaces(self):
        for shell in SHELLS:
            for form in (
                f"{shell} -c 'git commit -m x'",
                f'{shell} -c "git commit -m x"',
                f"{shell} -lc 'git commit -m x'",
                f"{shell} -ec 'git commit -m x'",
                f"/bin/{shell} -c 'git commit -m x'",
                f"sudo {shell} -c 'git commit -m x'",
                f"timeout 5 {shell} -c 'git commit -m x'",
                f"env -i {shell} -c 'git commit -m x'",
                f"FOO=1 {shell} -c 'git commit -m x'",
            ):
                self.check_runs(form, form)
                with self.subTest(f"wrapped string: {form}"):
                    self.assertEqual(wrapped_command_strings(form), ["git commit -m x"])

    def test_c_wrapper_position_survives_behind_a_cd(self):
        for shell in SHELLS:
            command = f"cd /other && {shell} -c 'git commit -m x'"
            with self.subTest(command=command):
                self.assertTrue(runs_before(command, CD, COMMIT))

    def test_nested_wrappers_surface_within_the_depth_bound(self):
        self.check_runs("shell in a shell", "bash -c \"sh -c 'git commit -m x'\"")
        self.check_runs("eval in a shell", "bash -c \"eval 'git commit -m x'\"")
        self.check_runs("shell in eval", "eval \"zsh -c 'git commit -m x'\"")

    def test_the_quote_strip_erases_a_wrapped_span_and_the_wrapper_reader_returns_it(self):
        # What strip_quoted_indexed does to the argument is the evasion this
        # whole family is about: the view holds only a placeholder, so a
        # reader that stopped at the stripped view would never see the commit.
        for command in (
            "bash -c 'git commit -m x'",
            'eval "git commit -m x"',
            "sh -ec 'git commit -m x'",
        ):
            with self.subTest(command=command):
                view, _values = strip_quoted_indexed(command)
                self.assertNotIn("commit", view)
                self.assertEqual(wrapped_command_strings(command), ["git commit -m x"])

    def test_controls_a_wrapper_word_that_executes_nothing_stays_data(self):
        self.check_inert("echo of a wrapper line", "echo bash -c 'git commit -m x'")
        self.check_inert("a quoted line is only an argument", "echo 'eval git commit -m x'")
        self.check_inert("grep for the words", "grep -n 'git commit' notes.txt")
        self.check_inert("shell with a script file", "bash run.sh 'git commit -m x'")
        self.check_inert("shell flag without -c", "bash -x run.sh")
        self.check_inert("a non-shell dash-c", "gcc -c 'git commit -m x'")
        with self.subTest("trap listing form is not an action"):
            self.assertEqual(wrapped_command_strings("trap -p"), [])


if __name__ == "__main__":
    unittest.main()
