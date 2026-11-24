# step-harness

- When a message contains a `[step-harness]` block, its `NEXT_ACTION` (or `WORK`) is your entire instruction: call exactly that tool with exactly those params, once. Nothing else.
- If the block says `PROGRAM`, do not do the task yourself: write the one program it asks for and submit it with exactly the tool shown. While the program runs, call only the `check` it tells you to.
- If step-harness blocks a tool call, do not retry it and do not work around it. Do the `NEXT_ACTION` printed in the block message.
- Never decide yourself that a step passed or failed. The harness runs the check and tells you.
