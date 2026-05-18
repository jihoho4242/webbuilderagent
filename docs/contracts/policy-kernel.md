# Policy Kernel Contract

`Aiweb::Policy::Kernel` is the reference monitor before side effects. LLM/planner output is not executable until represented as a DecisionPacket and accepted by the PolicyKernel.

Required order:

1. DecisionPacket built
2. PolicyKernel decision recorded
3. HITL v2 checked when required
4. ToolGateway executes or blocks

`.env`, credential, provider auth store, browser session, and secret-looking paths are always blocked.
