# Tool Gateway Contract

`Aiweb::Tools::Gateway` is the ToolGateway canonical boundary for side-effect-capable tools. Tools must declare risk tier, permission tier, side-effect class, owner, and dry-run support in `configs/tool_registry.yaml`.

Allowed event order:

```text
tool.requested -> policy.decision -> tool.started|tool.blocked -> tool.finished
```

Legacy fixed pipelines such as verify-loop may remain only as gateway-routed verification bundle tools, not as the canonical agent engine.
