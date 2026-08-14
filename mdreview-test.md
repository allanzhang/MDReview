# MDReview 基线验证文档

## 数学公式
行内公式 $E=mc^2$ 与块级公式：

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

## 代码高亮

```python
def hello(name: str) -> str:
    return f"Hello, {name}!"

print(hello("MDReview"))
```

## 表格与任务列表

| 功能 | 状态 |
|---|---|
| 搜索面板 | 待验证 |
| 外观切换 | 待验证 |

- [x] 构建通过
- [ ] 导出 HTML
- [ ] 导出 PDF

## Mermaid 图表

```mermaid
graph LR
  A[构建] --> B[验证] --> C[通过]
```

## 扩展语法
==高亮文字==、~删除线~、H~2~O、x^2^、emoji 🎉

---

> 结束。这个文档用于三步实机验证。
