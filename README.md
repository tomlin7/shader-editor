# `shader editor (zig+webgpu)`

minimal native desktop shader editor written in zig. uses `wgpu-native` c api directly and `glfw` for windowing

<img alt="image" src="https://github.com/user-attachments/assets/862fb2f3-1d89-48a1-b4c9-5dcfe603decf" />

## `building`

```bash
zig build run
```

once running, a colorful triangle will render. leave the window open. open `shader.wgsl` and start editing.

if you write a syntax error, the console will print `=== webgpi compilation error ===`, and the window will safely keep animating the old shader without crashing.
