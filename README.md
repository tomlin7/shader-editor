# `shader editor (zig+webgpu)`

minimal native desktop shader editor written in zig. uses `wgpu-native` c api directly and `glfw` for windowing


## `building`

```bash
zig build run
```

once running, a colorful triangle will render. leave the window open. open `shader.wgsl` and start editing.

if you write a syntax error, the console will print `=== webgpi compilation error ===`, and the window will safely keep animating the old shader without crashing.
