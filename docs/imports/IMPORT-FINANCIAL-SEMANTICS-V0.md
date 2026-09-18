# Import → Financial Semantics V0

## Rule
An approved identity match proves only canonical identity. It does not prove commission reporting, payment, settlement, or revenue.

## Evidence classification
Each adapter/source must declare the semantic meaning of a financial column before it can call the financial publisher:
- `commercial_offer`: table/rate/commission offer only. Never creates financial events.
- `production_report`: proves production/status; financial values may be reported only when the source explicitly labels them as commission due/reported.
- `commission_statement`: may publish `commission_reported` when amount, component and proposal identity are deterministic.
- `payment_statement`: may publish `payment_received` only when the source explicitly proves settlement/payment and the proposal/component match is deterministic.
- `network_payment_statement`: may publish `downstream_paid` with deterministic payee/network lineage.

## Current known source evidence
- Daycoval Governo do Acre table file: commercial offer/table evidence, not payment.
- Efetiva Mais table/report evidence previously inspected: treat as commercial offer unless a separate commission/payment statement proves otherwise.
- Bevicred table file: commercial offer/channel table evidence, not payment.

## Fail-closed requirements
No financial publication when amount semantics, payer/payee, component, proposal, currency, or settlement meaning is ambiguous. Ambiguity becomes human review; manual review itself must record the original evidence reference.
