# HITL Approval Artifact v2 Contract

HITL approval v2 is hash-bound, time-bound, and single-use. It binds run id, DecisionPacket ids, action diff hash, args hash, evidence hash, approval hash, expiry, approver, and second reviewer for L4/L5 risk.

Any mismatch, expiry, reuse, or missing second reviewer for L4/L5 fails closed before ToolGateway execution.
