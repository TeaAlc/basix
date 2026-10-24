"""Static policy coverage; actual tool receipt and authorization require runtime evidence."""
from pathlib import Path
import json
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
SKILLS = REPO / 'src/skills'


def text(skill):
    """Return normalized instructions; skill is the canonical skill directory name."""
    return ' '.join((SKILLS / skill / 'SKILL.md').read_text().split())


class SilentPolicyTests(unittest.TestCase):
    def test_schema_only_new_protocol_and_terminal_statuses(self):
        """Verify this policy boundary; self is the unittest test instance."""
        schema = json.loads((SKILLS / 'basix-agent-authoring/references/message.schema.json').read_text())
        self.assertEqual(schema['properties']['contract_version']['const'], '2.0')
        self.assertEqual(set(schema['properties']['message_type']['enum']),
                         {'issue', 'permission_request', 'final_result'})
        self.assertNotIn('plan_data', schema['$defs'])
        terminal = [rule for rule in schema['allOf']
                    if rule['if']['properties'] == {'message_type': {'const': 'final_result'}}
                    and 'status' in rule['then']['properties']]
        self.assertEqual(terminal[0]['then']['properties']['status']['enum'],
                         ['completed', 'completed_with_errors', 'failed'])

    def test_portable_word_patterns_enforce_exact_limits(self):
        """Verify this policy boundary; self is the unittest test instance."""
        schema = json.loads((SKILLS / 'basix-agent-authoring/references/message.schema.json').read_text())
        insight = schema['$defs']['final_data']['then']['properties']['subagent_insights']['items']['pattern']
        summary = schema['allOf'][0]['then']['properties']['summary']['pattern']
        for pattern, limit in ((insight, 24), (summary, 32)):
            self.assertIn('\\u0085', pattern)
            for separator in (' ', '\n', '\u001c', '\u0085', '\u3000'):
                self.assertIsNotNone(re.search(pattern, separator.join(['word'] * limit)))
                self.assertIsNone(re.search(pattern, separator.join(['word'] * (limit + 1))))
            for value in ('', ' \t\n\u0085\u3000'):
                self.assertIsNone(re.search(pattern, value))

    def test_dispatch_resources_and_acceptance_boundaries(self):
        """Verify this policy boundary; self is the unittest test instance."""
        management = text('basix-subagent-management')
        for requirement in (
            'model="gpt-6.1-sol"', 'reasoning_effort="low"', 'fork_turns="none"',
            'Unsupported model/tool settings block dispatch', 'never silently substitute',
            'at most three ACTIVE plan executors, six ACTIVE read-only helpers and nine ACTIVE descendants overall',
            'Grant nested slots explicitly', 'disjoint writes and isolated mutable resources/logs',
            'sequential predecessor acceptance', 'delivered final, inactivity, successful tests and accepted result separately',
            'never twice for duplicate final delivery', 'independently complete assignment',
            'complete assigned feature plan', 'accepted predecessor evidence', 'canonical plan path',
            'the path never substitutes required context', "Never expose another plan's phases, tasks or intermediate checkpoints", 'baseline',
            'permissions', 'resources/log paths', 'acceptance checks', 'review budget',
            'bounded recovery criteria', 'checkpoint path', 'explicit efficiency-report decision',
            "Two read-only nested children exhaust their executor's helper grant",
        ):
            self.assertIn(requirement, management)

    def test_model_selection_preserves_specialists_and_independent_overrides(self):
        """Check normative dispatch boundaries; self is the unittest test instance."""
        management = text('basix-subagent-management')
        ordered = (
            '1. An explicit user override',
            '2. Otherwise use explicit settings',
            '3. For each field with no more explicit setting',
        )
        positions = [management.index(rule) for rule in ordered]
        self.assertEqual(positions, sorted(positions))
        for requirement in (
            'Resolve model and reasoning effort independently for every dispatch',
            'A model-only override retains the applicable effort',
            'Native specialists always retain their configured model and effort',
            'An incidental generic skill must not silently override role-specific native configuration',
            'If equally specific applicable directives conflict, fail closed',
            'pager, researcher and verifier assignments keep their native roles and settings',
            'Generic executors use the fallback only when no more explicit setting applies',
            'including unsupported selected effort',
        ):
            self.assertIn(requirement, management)
        self.assertNotIn('For each root-delegated saved plan, use a generic executor with exactly', management)

    def test_model_precedence_consumers_and_authoring_scope(self):
        """Check consumer scope and native defaults; self is the test instance."""
        for path in ('README.md', 'src/docs/agents.md', 'src/docs/skills.md'):
            content = ' '.join((REPO / path).read_text().split())
            with self.subTest(path=path):
                self.assertIn('explicit user override, applicable specialist/skill settings, then', content)
                self.assertIn('`gpt-6.1-sol`/`low` runtime fallback', content)
                self.assertIn('retains applicable effort', content)
                self.assertIn('preserve native specialist routing and configured settings', content)
                self.assertIn('unsupported selected settings block dispatch without substitution', content.lower())
        planning = text('basix-planning')
        for requirement in ('mandatory management/Contract 2.0 boundary', 'model/effort precedence',
                            'specialist routing, defaults, no-fork dispatch', 'unsupported-setting rejection'):
            self.assertIn(requirement, planning)
        for path in ('SKILL.md', 'references/model-classification.md'):
            content = ' '.join((SKILLS / 'basix-agent-authoring' / path).read_text().split())
            with self.subTest(path=path):
                self.assertIn('native authoring defaults are explicit specialized rules', content)
                self.assertIn('`gpt-6-luna` at classified effort', content)
                self.assertIn('a model-only override retains applicable effort', content)

    def test_wait_recovery_and_no_automatic_cancellation(self):
        """Verify this policy boundary; self is the unittest test instance."""
        management = text('basix-subagent-management')
        for requirement in (
            'timeout_ms: 1800000', 'Early delivery returns promptly',
            'bounded root budgets are separate from tool timeout',
            'finished child missing its final triggers one bounded lifecycle diagnosis',
            'not automatic failure/cancellation, short polling, status demands or unconditional infinite wait',
            'Assess remaining budget and evidence',
        ):
            self.assertIn(requirement, management)

    def test_checkpoint_and_companion_lifecycle(self):
        """Verify this policy boundary; self is the unittest test instance."""
        planning = text('basix-planning')
        for requirement in (
            'task/goal, next steps', 'owned scope/resources/permissions', 'completed QS and log paths',
            'blockers, report flag, contract version, logical sequence and cycle revision',
            'Never put transient state in memory', 'Resume without a transmitted plan, status message or context fork',
            'it is not compulsory', 'Before assigning/performing requested analysis',
            'Check for an adjacent', 'even without a new report request',
            '[efficiency-analysis.md](references/efficiency-analysis.md)',
        ):
            self.assertIn(requirement, planning)
        reference = SKILLS / 'basix-planning/references/efficiency-analysis.md'
        analysis = ' '.join(reference.read_text().split())
        for requirement in (
            'foo-001_efficency_analysis.md', 'A companion is not a numbered plan',
            'explicitly grant write ownership', 'read-only context permission never grants writes',
            'explicitly authorized update/merge or preservation', 'task/cycle attribution',
            'check both destination collisions before moving either', 'Respect ignore rules',
            'Failed attempts still require requested analysis', 'no filler',
            'Session-only totals cannot establish task waste or be allocated by guess',
            'parent waiting/review and human delay',
            'cause, evidence, effect on work, intervention, likely benefit and uncertainty',
            'newly authorized frozen cycle',
            'Unchanged-target compaction restores checkpoint state',
        ):
            self.assertIn(requirement, analysis)
        for target in re.findall(r'\[[^]]+\]\(([^)]+)\)', reference.read_text()):
            self.assertTrue((reference.parent / target).is_file(), target)

    def test_parallel_dependencies_and_git_boundaries(self):
        """Check scheduling and Git safeguards; self is the test instance."""
        planning = text('basix-planning')
        for requirement in (
            'explicit dependencies govern execution, including across phases',
            'accepted by their responsible parents', 'concurrent writes are disjoint',
            'Parallel implementation runs across independent whole plans',
            'within a plan, delegated parallel work is limited to granted read-only exploration/research',
            'Parallelize only when expected benefit outweighs dispatch/context/synthesis costs',
            'Ordinary serial work needs no parallel template',
            'Joins await named accepted results, not every agent or a phase boundary',
            'terminal delivery, inactivity, passing checks and parent acceptance',
            'Failures block descendants', 'requiring reassessment', 'replans omitted/deferred scope',
            'research and non-Git work too', '[parallel-git.md](references/parallel-git.md) completely',
        ):
            self.assertIn(requirement, planning)
        git = ' '.join((SKILLS / 'basix-planning/references/parallel-git.md').read_text().split())
        for requirement in (
            'Read-only agents need no feature branch or worktree', 'expected tip',
            'accepted integrated predecessor base', 'separate worktree',
            'Shared Git metadata and ref operations are serialized by root',
            'Only root creates a feature checkpoint commit', 'assigned scope-local checks',
            'Future integration checks are not checkpoint prerequisites', 'no scoped checkpoint exception is granted here',
            'no unresolved relevant failure', 'exact accepted checkpoint SHA',
            'merges exact accepted SHAs in dependency order',
            'Corrections invalidate affected acceptance and test evidence',
            'aggregate checks on the integrated result', 'frozen independent review',
            'atomically guards the target update', 'comparing then blindly updating is insufficient',
            'exact integrated tested tree', "checked-out target's index/worktree consistent",
            'new frozen review', 'Never force-overwrite intervening changes',
            'does not imply permission to push or publish',
            'only identified task-owned branches', 'unmerged or uncommitted work',
            "Never reset, discard or clean the user's changes",
        ):
            self.assertIn(requirement, git)

    def test_feature_plan_opacity_and_incremental_evidence(self):
        """Keep opaque dispatch and final verification distinct from merge checks."""
        feature = ' '.join((SKILLS / 'basix-planning/references/feature-execution.md').read_text().split())
        for rule in ('Root normally creates and consolidates plans',
                     'not an empty plan', 'never release a dependent plan',
                     'never repair a cycle by exposing',
                     'performs implementation itself', 'explicit exclusive transfer',
                     'Final-gate failure keeps the work order open',
                     'Declare that executor once at plan level',
                     "internal implementation tasks belong to it without subagent labels",
                     'executor never waits for its own Root acceptance/integration before delivering its terminal result'):
            self.assertIn(rule, feature)
        git = ' '.join((SKILLS / 'basix-planning/references/parallel-git.md').read_text().split())
        for rule in ('no automatic full-suite rerun for each plan',
                     'environment assumptions remain applicable',
                     'target drift alone does not require another aggregate',
                     'After every plan is integrated and writers are inactive',
                     'full final gate for the corrected result'):
            self.assertIn(rule, git)

    def test_independent_analytical_workflows_stay_separate(self):
        """Verify this policy boundary; self is the unittest test instance."""
        self.assertIn("not this workflow's full recovery report format", text('basix-subagent-efficiency'))
        experience = text('basix-experience')
        self.assertIn('five opportunities are not imposed on that companion', experience)
        self.assertIn('thread/tree telemetry, not task/cycle attribution', experience)


if __name__ == '__main__':
    unittest.main()
