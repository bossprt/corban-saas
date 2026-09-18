# Financial Truth / Ledger V0 — Design Gate

## Purpose
Corban OS must separate commercial expectation from bank/partner reporting and from money actually received or owed.

## Facts that must never collapse into one field
- own production vs network production
- gross commission generated
- upfront commission
- deferred nominal commission
- deferred anticipation factor and equivalent anticipated amount
- campaign / volume bonus
- downstream share
- tenant economic entitlement
- expected receivable/payable
- reported amount
- received/paid amount
- divergence
- reversal / clawback / adjustment

## Invariants
1. Proposal and commercial-rule snapshots are immutable historical inputs.
2. Money uses numeric/decimal, never Float.
3. A matching proposal does not prove payment.
4. Reported, expected and received are separate evidence states.
5. Ledger entries are append-only. Corrections use reversal/compensating entries.
6. Every ledger entry points to evidence/source lineage and, when applicable, proposal + channel + rule/split snapshot.
7. Idempotency key prevents duplicate financial facts from repeated imports/webhooks.
8. AI may suggest classification/matching but cannot publish financial truth.
9. Ambiguous payer/payee, split, component or proposal becomes human_required.
10. Deferred anticipation consumes the deferred entitlement according to the frozen rule; it is not upfront + full deferred.

## Proposed V0 entities
- financial_accounts: tenant-scoped logical accounts (receivable, payable, revenue, bonus, clearing).
- financial_events: immutable domain fact with proposal/channel/producer/payer and event type.
- financial_entries: balanced debit/credit-style lines or signed movements tied to one event.
- financial_evidence_links: links event to import batch/raw/decision/payment evidence.
- reconciliation_cases: expected vs reported vs settled divergence and resolution state.

## Event types
commission_expected, network_share_expected, bonus_expected, commission_reported, payment_received, downstream_payable, downstream_paid, reversal, adjustment.

## Human Gate
Publishing a financial event requires deterministic source evidence or explicit authorized review. No file import directly writes received revenue.
