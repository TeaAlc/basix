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
            'at most three ACTIVE descendants including nested children before every spawn',
            'Grant nested slots explicitly', 'disjoint writes and isolated mutable resources/logs',
            'sequential predecessor acceptance', 'delivered final, inactivity, successful tests and accepted result separately',
            'never twice for duplicate final delivery', 'complete plan', 'baseline',
            'permissions', 'resources/log paths', 'acceptance checks', 'review budget',
            'bounded recovery criteria', 'checkpoint path', 'explicit efficiency-report decision',
            'Two nested children plus their active parent exhaust three slots',
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
        self.assertIn('for each unspecified field independently', planning)
        self.assertIn('Saved plans do not replace native specialist routing or configured model/effort', planning)
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
            'pending blockers, report flag, contract version, logical sequence and cycle revision',
            'Never use memory for transient state', 'Resume without a plan or status message',
            'no compulsory report for every task', 'foo-001_efficency_analysis.md',
            'A companion is not a numbered plan', 'explicit write ownership',
            'read-only context permission does not grant writes',
            'explicit authorized update/merge or preservation', 'task/cycle attribution',
            'check both destination collisions before moving either', 'Respect ignore rules',
            'Failed attempts still need requested analysis', 'no filler',
            'Session-only totals cannot prove task waste', 'parent waiting/review and human delay',
            'cause, evidence, effect on work, intervention, likely benefit and uncertainty',
        ):
            self.assertIn(requirement, planning)

    def test_independent_analytical_workflows_stay_separate(self):
        """Verify this policy boundary; self is the unittest test instance."""
        self.assertIn("not this workflow's full recovery report format", text('basix-subagent-efficiency'))
        experience = text('basix-experience')
        self.assertIn('five opportunities are not imposed on that companion', experience)
        self.assertIn('thread/tree telemetry, not task/cycle attribution', experience)


if __name__ == '__main__':
    unittest.main()
