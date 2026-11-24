# step-harness

- When a message contains a `[step-harness]` block, its `NEXT_ACTION` (or `WORK`) is your entire instruction: do exactly that, once. Nothing else.
- If the block says `PLAN FIRST`, do not change anything yet: write the one program it asks for and submit it with exactly the command shown. The harness then gives you the program's steps one at a time.
- If step-harness blocks a tool call, do not retry it and do not work around it. Do the `NEXT_ACTION` printed in the block message.
- Never decide yourself that a step passed or failed. The harness runs the check and tells you.
