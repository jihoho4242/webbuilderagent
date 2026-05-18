# Agent OS Constitution Contract

`configs/constitution.yaml` is the immutable Agent OS safety contract. Runtime, resume, replay, and P5 evidence must bind to its `sha256:` content hash.

Critical invariants:

- NO_SELF_PERMISSION_ESCALATION
- NO_POLICY_KERNEL_BYPASS
- NO_HITL_DOWNGRADE
- NO_EVAL_THRESHOLD_DOWNGRADE
- NO_SECRET_READ

Changing this contract requires a signed PR, security owner approval, and two-person review for L4/L5 authority paths. Self-improvement may only create proposals against constitution-adjacent files; it may not directly patch or weaken them.
