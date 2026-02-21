# `shader editor (zig+webgpu)`

minimal native desktop shader editor written in zig. uses `wgpu-native` c api directly and `glfw` for windowing

<img alt="image" src="https://github.com/user-attachments/assets/62a87b10-a891-4135-b1d5-3a5ae90bc916" />

## `building`

```bash
zig build run
```

once running, a colorful triangle will render. leave the window open. open `shader.wgsl` and start editing.

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   text editor        │   shader preview     │
│   (editor.zig)       │   (viewport render)  │
│                      │                      │
│   - line numbers     │   - your wgsl shader │
│   - blinking cursor  │   - live triangle    │
│   - syntax editing   │   - uniforms: time,  │
│                      │     resolution       │
├──────────────────────┤                      │
│ error/success panel  │                      │
└──────────────────────┴──────────────────────┘
```

- type in the left panel to edit WGSL
- arrow keys to navigate
- enter for new lines, backspace to delete
- ctrl+s to compile — preview updates on success, red error panel on failure
- last valid shader keeps rendering if compilation fails

if you write a syntax error, the console will print `=== webgpi compilation error ===`, and the window will safely keep animating the old shader without crashing.
