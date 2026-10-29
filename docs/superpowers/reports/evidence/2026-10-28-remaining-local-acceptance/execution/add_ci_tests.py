from pathlib import Path
p=Path('tool/test_player_v2_gate.py');s=p.read_text();s=s.replace('import tempfile\n','import tempfile\nimport textwrap\n')
i=s.index('    def test_ci_stage_is_labeled_as_a_shard')
s=s[:i]+'''    def test_root_dependency_files_select_both_native_unit_shards(self) -> None:
        for path in ("pubspec.lock", "pubspec.yaml"):
            for stage, marker in (("android-unit", "android-jvm-unit"),
                                  ("apple-unit", "apple-ios-native-unit")):
                with self.subTest(path=path, stage=stage):
                    result = run_gate("--quick", "--stage", stage,
                                      YL_GATE_CHANGED_PATHS_OVERRIDE=path)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertIn("PLAYER_V2_STEP " + marker, result.stdout)

    def test_actual_workflow_selects_native_and_consumers_for_root_dependencies(self) -> None:
        # Execute the real workflow selection shell against real Git changes;
        # asserting only its regex text would miss broken branching or outputs.
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        selection = workflow.split("      - id: select\\n", 1)[1].split("\\n  foundation:", 1)[0]
        shell = textwrap.dedent(selection.split("        run: |\\n", 1)[1])
        cases = (("pubspec.lock", "true"), ("pubspec.yaml", "true"),
                 ("docs/release-notes.md", "false"))
        for path, expected in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory(prefix="yl-ci-select-") as temp:
                checkout = Path(temp)
                def git(*args):
                    return subprocess.check_output(["git", *args], cwd=checkout, text=True).strip()
                git("init", "-q")
                git("config", "user.email", "gate@example.invalid")
                git("config", "user.name", "Gate Test")
                (checkout / "base").write_text("base\\n")
                git("add", ".")
                git("commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                target = checkout / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("dependency update\\n")
                git("add", ".")
                git("commit", "-qm", "change")
                output = checkout / "outputs"
                result = subprocess.run(["sh", "-eu", "-c", shell], cwd=checkout,
                    env=dict(os.environ, EVENT_NAME="push", EVENT_BASE=base, GITHUB_OUTPUT=str(output)),
                    text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual({key: values[key] for key in ("android", "apple", "consumers")},
                                 {key: expected for key in ("android", "apple", "consumers")})
                self.assertEqual(values["artifact"], "false")

'''+s[i:];p.write_text(s)
