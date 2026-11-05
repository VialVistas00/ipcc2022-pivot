# "最小单位"：一个程序从源码到跑出结果，最少要经过哪几步

## 结论先给

**六步**，一步都省不掉：

```
环境  →  源码  →  编译  →  链接  →  运行  →  输出
(gcc)    (pivot.c) (.o)     (pivot)  (ELF)    (result.txt)
```

可以写成一条命令（`gcc pivot.c -lm -o pivot && ./pivot`），但那只是**把六步折叠进一条命令行**，内部照样走完六步——用 `gcc -v` 就能看见它先后拉起 `cc1`（编译）、`as`（汇编）、`collect2/ld`（链接）。

---

## 逐步拆开：每步在干什么，我怎么确认

### 第 1 步 · 环境：编译器和库在不在

| 做什么 | 怎么确认 |
|---|---|
| 确认有编译器 | `which gcc` 有输出、`gcc --version` 打印版本 |
| 确认有数学库 | 本题用到 `pow / sqrt / fabs`，链接期需要 `libm`；漏 `-lm` 会在**链接**阶段报 `undefined reference to 'pow'` |
| 确认机器规模 | `lscpu`、`nproc`、`free -h`（本题 malloc 只有几十 KB，内存不是瓶颈） |

> 判断依据：**没有输出 = 没有装**。这一步错了，后面全错，但报错信息会误导你（看起来像"代码写错了"）。

### 第 2 步 · 源码：拿到的是不是能编的完整源码

```bash
wc -l pivot.c          # 267 行，单文件
head -12 pivot.c       # 4 个 include：stdio/stdlib/math/sys/time
head -1 uniformvector-2dim-5h.txt   # 2 500 2   ← dim n k
wc -l uniformvector-2dim-5h.txt      # 501 = 1 行头 + 500 行点
wc -l refer-2dim-5h.txt              # 2000 = 1000 max + 1000 min
```

> 判断依据：**源码 + 输入 + 基准输出三件套齐全**，而且从输入头一行就能读出规模（`dim=2, n=500, k=2`）——规模决定了后面要跑多久：组合数 `C(500,2) = 124750`。

### 第 3 步 · 编译：C → 汇编 → 目标文件

```bash
gcc -c pivot.c -o pivot.o          # 只编译+汇编，不链接
file pivot.o                       # → ELF 64-bit LSB relocatable（可重定位，还不能跑）
nm pivot.o | grep -E 'SumDistance|Combination'
#   0000000000000000 T SumDistance
#   00000000000001a0 T Combination     ← 符号已存在，但地址还是相对的（全 0 基准）
```

想看得更细：

```bash
gcc -E pivot.c | wc -l             # 预处理后行数（把 #include 全展开，会暴涨到几千行）
gcc -S pivot.c -o pivot.s          # 生成汇编，能肉眼看 pow/sqrt 是不是 call 出去的
gcc -v -c pivot.c -o /dev/null 2>&1 | grep -E 'cc1|as '
#   /usr/lib/gcc/.../cc1 ...        ← 前端：C → 汇编
#   as -v ...                       ← 汇编器：汇编 → .o
```

> 判断依据：`file` 说 *relocatable*（可重定位）而不是 *executable*，且 `nm` 能列出函数符号 = 编译成功、链接还没做。

### 第 4 步 · 链接：把 .o + libm + 启动代码拼成可执行文件

```bash
gcc pivot.o -o pivot -lm
file pivot                           # → ELF 64-bit LSB pie executable（可执行了）
ldd pivot                            # → libc.so.6, libm.so.6, ld-linux-x86-64.so.2
objdump -p pivot | grep NEEDED       # 同上，只是不经 shell
```

Windows 上等价物（本机用 w64devkit 验证过）：

```powershell
objdump -p pivot_O2.exe | Select-String 'DLL Name'
#   DLL Name: KERNEL32.dll
#   DLL Name: msvcrt.dll        ← pow/sqrt 由它提供，这就是 -lm 在 mingw 上的落点
nm pivot_O2.exe | Select-String 'SumDistance'
#   00000001400014c0 T SumDistance   ← 链接后地址变成了绝对（本例基址 0x140000000）
```

> 判断依据：**符号地址从相对变绝对**、`ldd` 能列出依赖库、`file` 变成 *executable*。如果这步失败，报错永远是 `undefined reference to ...`，而不是"代码有 Bug"。

### 第 5 步 · 运行：进程真的跑起来了

```bash
./pivot uniformvector-2dim-5h.txt    # 前台跑（几十秒~几分钟）
nohup ./pivot ... > run.log 2>&1 &   # 或者挂后台，SSH 断了也不死
tmux new -s pivot                    # 更好：会话可重连
```

怎么看它"真的在跑、而不是卡死"：

```bash
ps -o pid,etime,time,%cpu -C pivot   # CPU time 在涨 = 在算；etime 涨而 time 不涨 = 卡住了
top -p $(pgrep pivot)                # 单看这一个进程
```

> 判断依据：`%CPU` 接近 100（单线程）、CPU time 单调增长。

### 第 6 步 · 输出：结果对不对

```bash
ls -l result.txt                     # 程序在工作目录写出的结果文件
head -3 result.txt                   # 前 1000 行是 max（按目标函数值降序）
tail -3 result.txt                   # 后 1000 行是 min（升序）
diff result.txt refer-2dim-5h.txt && echo SAME     # ← 唯一的"跑通"判据
```

> 判断依据：**逐字节相同**。只要 diff 有差异，前面五步做得再漂亮都不算跑通。

---

## 一条命令跑完六步时，内部发生了什么

```bash
gcc pivot.c -lm -o pivot && ./pivot uniformvector-2dim-5h.txt && diff result.txt refer-2dim-5h.txt
```

`gcc` 这条命令里其实有四个程序接力：

| 顺序 | 实际执行的可执行文件 | 职责 | 产物 |
|---|---|---|---|
| 1 | `cc1` | 预处理 + 编译 | 汇编 `.s` |
| 2 | `as` | 汇编 | 目标文件 `.o` |
| 3 | `collect2` → `ld` | 链接（含 `-lm` 的 `libm`、`crt1.o` 启动代码） | 可执行 `pivot` |
| 4 | （内核 + `ld.so`） | 装载、动态链接、跳到 `_start` | 进程 |

`gcc -v` 会把这条链路完整打印出来——**这就是"最小单位"最容易自证的方式**。

---

## 为什么必须理解这一层（和本周后面两项的关系）

- **编译优化实验**：`-O0/-O1/-O2/-O3` 只影响第 3 步（cc1 生成的汇编），第 4~6 步完全不变 → 所以换选项后**结果不该变**，`diff` 一次就能证明；
- **perf**：perf 采样的是第 5 步的进程（用户态 PC 采样 + 硬件计数器），它看到的符号来自第 3~4 步留下的符号表 → 所以 perf 前要 `-g` 编一次，`perf report` 才能显示函数名而不是一串地址。
