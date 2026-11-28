# Native visuals — interactive output in Harness

## Product direction

**Harness is the workspace where agents turn an answer into something you can use.**

The first step is interactive output inside a conversation: explore a scenario, compare alternatives, and adjust assumptions without asking the model to rewrite a paragraph for every change. Graff supplies the reasoning and tools; Harness supplies a consistent, native interface across agents.

Lead with a concrete job rather than “AI-generated UI”: “Compare three rollout plans, adjust the expected traffic, and see the capacity trade-off.” A useful demo starts with a question, produces a small interactive model, changes one assumption, then explains the decision. It should distinguish synthetic examples from measured results.

This is complementary to building real products. Project previews, browser inspection, and screenshot feedback remain the right workflow for editing a website or application. Native visuals are small conversational tools, not a replacement IDE, browser, or general application platform.

## Scope

This implementation is deliberately small, inspired by [Zeron's native visuals](https://github.com/zeronsh/zeron/pull/900). The desktop sandbox is `apps/nano/src/visual_luau.zig`, drawn by `view_visual.zig` with its cache in `app_visuals.zig`; the iOS app runs the same scripts in `apps/ios/Harness/Visual/`.

- An agent publishes a titled Luau script with `show_visual` in an active Harness turn, including Graff turns using Harness MCP.
- The script produces themed native rows, columns, text, statistics, bar charts, buttons, toggles, sliders, and rules.
- Scripts have no filesystem, process, network, module-loading, or application API access. Both initial rendering and interactions run under memory, time, tree, and payload limits.
- The title and bounded source are explicit conversation content and synchronize with the transcript. Do not embed secrets or private context that should not be part of the conversation.
- Interaction state is local and temporary. Reopening a conversation, eviction from the bounded resident cache, or restarting the app resets it to the script's initial state. Changing a control does not send a model request or run a shell command.

Not included: arbitrary HTML/CSS, asset loading, 3D, shaders, animation loops, persistent/shared control state, or automatic screenshot feedback to the model.

Use matching desktop app and engine versions, as shipped together by Harness. Mixed-version app/engine connections are not compatibility-negotiated.

## Agent authoring

Call `show_visual` with a human-readable `title` and a `script` string. The tool is only available with a chat context and publishes into that chat's active turn. It does not select a destination supplied by the agent. Source is limited to 64 KiB and the title to 200 characters. The script returns a render function; state belongs in locals outside that function:

```lua
local traffic = 50
return function()
    return ui.column{
        ui.text('Illustrative capacity scenario — not a benchmark'),
        ui.chart{
            label='Requests per second',
            values={traffic, traffic * 1.5, traffic * 2},
            labels={'Current', 'Growth', 'Peak'},
        },
        ui.slider{
            label='Baseline requests per second', value=traffic, min=1, max=100,
            onChange=function(value) traffic = value end,
        },
    }
end
```

The host owns colors, fonts, spacing, and control appearance. Unknown nodes and styling properties are errors, not silently ignored CSS. Arrays must be dense; numbers must be finite. Limits per render are 512 nodes, depth 24, 8 KiB aggregate text, and 256 aggregate chart values. Each sandbox has a 16 MiB memory budget and a 20 ms execution deadline. Luau interrupts are cooperative: native library calls and compilation also receive post-call deadline checks, not hard real-time preemption.

Initial validation checks setup and the first render, not every possible event path. An interaction that errors or exceeds a limit becomes a visible unavailable state rather than an app capability escalation. Scripts must keep both rendering and handlers small and deterministic. A successful publication acknowledges durable conversation publication, not proof that every handler works or that every client can render the visual.

## Tests

From `apps/nano`, `zig build test-visual` runs the sandbox's own tests (`visual_luau.zig`: rendering, typed control values, the capability lockdown and the deadlines). The engine side is `cargo test -p harness-engine --test show_visual`, and iOS has `VisualRuntimeTests`.

Up to eight visuals stay resident per transcript (`max_cached` in `app_visuals.zig`); an evicted visual restarts from its initial state when viewed again.
