# Tool Gateway Contract

`Aiweb::Tools::Gateway` is the ToolGateway canonical boundary for side-effect-capable tools. Tools must declare risk tier, permission tier, side-effect class, owner, and dry-run support in `configs/tool_registry.yaml`.

Allowed event order:

```text
tool.requested -> policy.decision -> tool.started|tool.blocked -> tool.finished
```

Legacy fixed pipelines such as the old verify-loop script must not remain as executable agent engines. `verify-loop` may exist only as an engine-run compatibility shim with no bespoke build/preview/QA/repair script.
