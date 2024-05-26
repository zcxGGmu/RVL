# -1 说明

这是一个用于汇总的文档，和 **kvm-patch工作流** 有关的一切，我都会整理于此，后续再进行文档切分。

- [ ] 订阅kvm-riscv邮件列表
- [ ] 向linux提交patch流程以及注意事项
- [ ] patch来源
  - [ ] 内核配置项
  - [ ] `kvm-api.rst`
  - [ ] bugzilla/syzbot
  - [ ] lkml

# 0 问题

* [ez4yunfeng2/riscv-kvm-demo (github.com)](https://github.com/ez4yunfeng2/riscv-kvm-demo)





# 1 参与riscv kvm

1. 填写email/name：[kvm-riscv Info Page (infradead.org)](https://lists.infradead.org/mailman/listinfo/kvm-riscv)；
2. 后续，用上述email发送邮件至 `kvm-riscv-join@lists.infradead.org`，邮件内容仅添加纯文本的 `subscribe`，标题可以不用写。







# 2 向Linux提交PATCH流程

[RISC-V Linux 内核开发与 Upstream 实践 - 谭老师_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV1cK4y1w7eT/?spm_id_from=333.999.0.0&vd_source=e97ae8f8b8ae2ceb4dd6eec6f1e33ee9)

[向 Linux kernel 社区提交patch补丁步骤总结（已验证成功）_发patch包-CSDN博客](https://blog.csdn.net/jcf147/article/details/123719000#:~:text=一、详细步骤 1 1.安装git和git send-email yum install git ...,0 warnings。 ... 8 8.测试发送 在正式发送之前，先发给自己测试一下： ... 更多项目)

[谢宝友: 手把手教你给Linux内核发patch - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/87955006)

[[linux内核\][邮件列表]: 如何给linux kernel 提交 patch - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/476648206)

[【学习分享】 记录开源小白的第一次 PR - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/528512418)

---

## 2.1 准备工作

在开始工作之前，请准备如下工作：

1. **安装一份Linux**

   不论是ubuntu、centos还是其他Linux发行版本，都是可以的。我个人习惯使用ubuntu 22.04版本。

2. **安装Git**

   默认的Linux发行版，一般都已经安装好git。如果没有，随便找一本git的书都可以。这里不详述。

3. **配置git**

   * **配置用户名和邮箱**

     在配置用户名的时候，请注意社区朋友习惯用英语沟通，也就是名在前，姓在后。这一点会影响社区邮件讨论，因此需要留意。在配置邮箱时，也要注意。社区会将国内某些著名的邮件服务器屏蔽。因此建议你申请一个gmail邮箱。以下是我的配置：

     ```shell
     $git config -l | grep "user"
     user.email=baoyou.xie@linaro.org
     user.name=Baoyou Xie
     ```

   * **配置 sendemail**

     你可以手工修改~/.gitconfig，或者git仓库下的.git/config文件，添加 `[sendemail]` 节。该配置用于指定发送补丁时用到的邮件服务器参数。以下是我的配置，供参考：

     ```sh
     [sendemail]
           smtp encryption= tls
           smtp server= smtp.gmail.com
           smtp user= baoyou.xie@linaro.org
           smtp serverport= 587
     ```
     
     gmail邮箱的配置比较麻烦，需要按照google的说明，制作证书。配置完成后，请用如下命令，向自己发送一个测试补丁：

     ```shell
     git send-email your.patch --to your.mail --cc your.mail
     ```
     
   * **下载源码**
   
     首先，请用如下命令，拉取linus维护的Linux主分支代码到本地：
   
     ```sh
     git clone ssh://git@dev-private.git.linaro.org/zte/kernel.git
     ```
   
     这个过程比较长，请耐心等待。一般情况下，Linux主分支代码不够新，如果你基于这个代码制作补丁，很有可能不会顺利的合入到Maintainer那里，换句话说，Maintainer会将补丁发回给你，要求你重新制作。所以，一般情况下，你需要再用以下命令，添加其他分支，特别是 `linux-next` 分支。强调一下，你需要习惯基于 `linux-next` 分支进行工作。
   
     ```sh
     git remote add linux-nexthttps://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git
     git remote add staging https://git.kernel.org/pub/scm/linux/kernel/git/gregkh/staging.git
     git remote add net git://git.kernel.org/pub/scm/linux/kernel/git/davem/net.git
     ```
   
     然后用如下命令拉取这三个分支的代码到本地：
   
     ```sh
     git fetch --tags linux-next
     git fetch --tags staging
     git fetch --tags net
     ```
   
     有些Maintainer维护了自己的代码分支，那么，你可以在内核源码目录 `\MAINTAINERS` 文件中，找一下相应文件的维护者，及其git地址。例如，watchdog模块的信息如下：
   
     ```sh
     WATCHDOGDEVICE DRIVERS
     M:      Wim Van Sebroeck <wim@iguana.be>
     R:      Guenter Roeck <linux@roeck-us.net>
     L:      linux-watchdog@vger.kernel.org
     W:      http://www.linux-watchdog.org/
     T:      gitgit://www.linux-watchdog.org/linux-watchdog.git
     S:      Maintained
     F:      Documentation/devicetree/bindings/watchdog/
     F:      Documentation/watchdog/
     F:      drivers/watchdog/
     F:      include/linux/watchdog.h
     F:      include/uapi/linux/watchdog.h
     ```
   
     其中，[http://www.linux-watchdog.org/linux-watchdog.git](https://link.zhihu.com/?target=http%3A//www.linux-watchdog.org/linux-watchdog.git) 是其git地址。你可以用如下命令拉取watchdog代码到本地：
   
     ```sh
     git remote add watchdog git://www.linux-watchdog.org/linux-watchdog.git
     git fetch --tags watchdog
     ```
   
     当然，这里友情提醒一下，MAINTAINERS里面的信息可能不一定准确，这时候你可能需要借助google，或者问一下社区的朋友，或者直接问一下作者本人。不过，一般情况下，基于 `linux-next` 分支工作不会有太大的问题。实在有问题再去打扰作者本人。
   
   * **阅读Documentation/SubmittingPatches，这很重要。**
   
   * **检出源码**
   
     ```sh
     git branch mybranch next-20170807
     ```
   
     这个命令表示将 `linux-next` 分支的20170807这个tag作为本地 `mybranch` 的基础。
   
     ```sh
     git checkout mybranch
     ```

## 2.2 寻找软柿子

如果没有奇遇，大厨一般都是从小工做起的。我们不可能一开始就维护一个重要的模块，或者修复一些非常重要的故障。那么我们应当怎么样入手参与社区？这当然要寻找软柿子了。拿着软柿子做出来的补丁，可以让Maintainer无法拒绝合入你的补丁。当然，这么做主要还是为了在Maintainer那里混个脸熟。否则，以后你发的重要补丁，人家可能不会理你。

**什么样的柿子最软？下面是答案：**

>1. 消除编译警告。
>2. 编码格式，例如注释里面的单词拼写错误、对齐不规范、代码格式不符合社区要求。

建议是从 **“消除编译警告”** 入手。社区很多大牛，都是这样成长起来的。

我们平时编译内核，基本上遇不到编译警告。是不是内核非常完美，没有编译警告，非矣！你用下面这个步骤试一下：

---

首先，配置内核，选择所有模块：

```sh
make ARCH=arm64 allmodconfig
```

请注意其中 `allmodconfig`，很有用的配置，我们暂且可以理解为，将所有模块都编译。这样我们就可以查找所有模块中的编译警告了。

下面这个命令开始编译所有模块：

```sh
make ARCH=arm64 EXTRA_CFLAGS="-Wmissing-declarations -Wmissing-prototypes" CROSS_COMPILE=/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-
```

* **EXTRA_CFLAGS="-Wmissing-declarations-Wmissing-prototypes"** 参数表示追踪所有missing-declarations、missing-prototypes类型的警告。
* **"CROSS_COMPILE=/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-"** 是指定交叉编译工具链路径，需要根据你的实际情况修改。当然，如果是x86架构，则不需要指定此参数。

---

在编译的过程中，我们发现如下错误：

```sh
scripts/Makefile.build:311:recipe for target 'drivers/staging/fsl-mc/bus/dpio/qbman-portal.o' failed
```

我们可以简单的忽略 `drivers/staging/fsl-mc/bus/dpio/qbman-portal.c` 这个文件。在 `drivers/staging/fsl-mc/bus/dpio/Makefile` 文件中，发现这个文件的编译依赖于宏 `CONFIG_FSL_MC_DPIO`。

于是，我们修改编译命令，以如下命令继续编译：

```sh
make CONFIG_ACPI_SPCR_TABLE=n ARCH=arm64 EXTRA_CFLAGS="-Wmissing-declarations -Wmissing-prototypes" CROSS_COMPILE=/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-
```

请注意该命令中的 `CONFIG_ACPI_SPCR_TABLE=n`，它强制关闭了 `CONFIG_ACPI_SPCR_TABLE` 配置。

当编译完成以后，我们是不是发现有很多警告？特别是在drivers目录下。下面是我在 `next-20170807` 版本中发现的警告：

```sh
 /dimsum/git/kernel.next/drivers/clk/samsung/clk-s3c2410.c:363:13:warning: no previous prototype for 's3c2410_common_clk_init'[-Wmissing-prototypes]
 void__init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
            ^
 CC     drivers/clk/samsung/clk-s3c2412.o
/dimsum/git/kernel.next/drivers/clk/samsung/clk-s3c2412.c:254:13:warning: no previous prototype for 's3c2412_common_clk_init'[-Wmissing-prototypes]
 void__init s3c2412_common_clk_init(struct device_node *np, unsigned long xti_f,
            ^
 CC     drivers/clk/samsung/clk-s3c2443.o
/dimsum/git/kernel.next/drivers/clk/samsung/clk-s3c2443.c:388:13:warning: no previous prototype for 's3c2443_common_clk_init' [-Wmissing-prototypes]
 void__init s3c2443_common_clk_init(struct device_node *np, unsigned long xti_f,
```

下一节，我们就基于这几个警告来制作补丁。

## 2.3 制作PATCH

### 修改错误，制作补丁

要消除这几个警告，当然很简单了。将这几个函数声明为 `static` 即可。下面是我的修改：

```sh
git diff
diff --git a/drivers/clk/samsung/clk-s3c2410.c b/drivers/clk/samsung/clk-s3c2410.c
index e0650c3..8f4fc5a 100644
--- a/drivers/clk/samsung/clk-s3c2410.c
+++ b/drivers/clk/samsung/clk-s3c2410.c
@@ -360,7 +360,7 @@ static void __inits3c2410_common_clk_register_fixed_ext(
       samsung_clk_register_alias(ctx, &xti_alias, 1);
 }
 
-void __init s3c2410_common_clk_init(structdevice_node *np, unsigned long xti_f,
+static void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
                                    intcurrent_soc,
                                    void__iomem *base)
 {
diff --git a/drivers/clk/samsung/clk-s3c2412.c b/drivers/clk/samsung/clk-s3c2412.c
index b8340a4..2a2ce06 100644
--- a/drivers/clk/samsung/clk-s3c2412.c
+++ b/drivers/clk/samsung/clk-s3c2412.c
@@ -251,7 +251,7 @@ static void __init s3c2412_common_clk_register_fixed_ext(
       samsung_clk_register_alias(ctx, &xti_alias, 1);
 }
 
-void __init s3c2412_common_clk_init(struct device_node *np, unsigned long xti_f,
+static void __init s3c2412_common_clk_init(struct device_node *np, unsigned long xti_f,
                                    unsigned long ext_f, void __iomem *base)
 {
       struct samsung_clk_provider *ctx;
diff --gita/drivers/clk/samsung/clk-s3c2443.c b/drivers/clk/samsung/clk-s3c2443.c
index abb935c..f0b88bf 100644
--- a/drivers/clk/samsung/clk-s3c2443.c
+++ b/drivers/clk/samsung/clk-s3c2443.c
@@ -385,7 +385,7 @@ static void __inits3c2443_common_clk_register_fixed_ext(
                               ARRAY_SIZE(s3c2443_common_frate_clks));
 }
 
-void __init s3c2443_common_clk_init(struct device_node *np, unsigned long xti_f,
+static void __init s3c2443_common_clk_init(struct device_node *np, unsigned long xti_f,
                                    int current_soc,
                                    void __iomem *base) 
```

再编译一次，警告果然被消除了。原来，社区工作如此简单：）。

但是请允许我浇一盆冷水！你先试着用下面的命令做一个补丁出来看看：

```sh
git add drivers/clk/samsung/clk-s3c2410.c
git add drivers/clk/samsung/clk-s3c2412.c
git add drivers/clk/samsung/clk-s3c2443.c
git commit drivers/clk/samsung/
[zxic/67184930591\] this is my test
3 files changed, 3 insertions(+), 3deletions(-)

git format-patch -s -v 1 -1
```

生成的补丁内容如下：

```sh
cat v1-0001-this-is-my-test.patch
From 493059190e9ca691cf08063ebaf945627a5568c7 Mon Sep 17 00:00:00 2001
From: Baoyou Xie<baoyou.xie@linaro.org>
Date: Thu, 17 Aug 2017 19:23:13 +0800
Subject: [PATCH v1] this is my test
 
Signed-off-by: Baoyou Xie<baoyou.xie@linaro.org>
---
 drivers/clk/samsung/clk-s3c2410.c | 2 +-
 drivers/clk/samsung/clk-s3c2412.c | 2 +-
 drivers/clk/samsung/clk-s3c2443.c | 2 +-
 3files changed, 3 insertions(+), 3 deletions(-)
 
diff --git a/drivers/clk/samsung/clk-s3c2410.c b/drivers/clk/samsung/clk-s3c2410.c
index e0650c3..8f4fc5a 100644
--- a/drivers/clk/samsung/clk-s3c2410.c
+++ b/drivers/clk/samsung/clk-s3c2410.c
@@ -360,7 +360,7 @@ static void __init s3c2410_common_clk_register_fixed_ext(
      samsung_clk_register_alias(ctx,&xti_alias, 1);
 }
 
-void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
+static void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
                               int current_soc,
                               void __iomem *base)
 {
diff --git a/drivers/clk/samsung/clk-s3c2412.c b/drivers/clk/samsung/clk-s3c2412.c
index b8340a4..2a2ce06 100644
--- a/drivers/clk/samsung/clk-s3c2412.c
+++ b/drivers/clk/samsung/clk-s3c2412.c
@@ -251,7 +251,7 @@ static void __inits3c2412_common_clk_register_fixed_ext(
      samsung_clk_register_alias(ctx,&xti_alias, 1);
 }
 
-void __init s3c2412_common_clk_init(structdevice_node *np, unsigned long xti_f,
+static void __init s3c2412_common_clk_init(struct device_node *np, unsigned long xti_f,
                               unsigned long ext_f, void __iomem *base)
 {
      struct samsung_clk_provider *ctx;
diff --git a/drivers/clk/samsung/clk-s3c2443.c b/drivers/clk/samsung/clk-s3c2443.c
index abb935c..f0b88bf 100644
--- a/drivers/clk/samsung/clk-s3c2443.c
+++ b/drivers/clk/samsung/clk-s3c2443.c
@@ -385,7 +385,7 @@ static void __inits3c2443_common_clk_register_fixed_ext(
                           ARRAY_SIZE(s3c2443_common_frate_clks));
 }
 
-void __init s3c2443_common_clk_init(structdevice_node *np, unsigned long xti_f,
+static void __init s3c2443_common_clk_init(struct device_node *np, unsigned long xti_f,
                               int current_soc,
                               void __iomem *base)
 {
--
2.7.4
```

你可以试着用 `git send-email v1-0001-this-is-my-test.patch --to baoyou.xie@linaro.org` 将补丁发给Maintainer。记得准备好一个盆子，接大家的口水：）

在制作正确的补丁之前，我们需要这个错误的补丁错在何处：

> * 应该将它拆分成三个补丁。
>
>   也许这一点值得商酌，因为这三个文件都是同一个驱动：`clk: samsung`。也许Maintainer认为它是同一个驱动，做成一个补丁也是可以的。我觉得应该拆分成三个。当然了，应当以Maintainer的意见为准。不同的Maintainer也许会有不同的意见。
>
> * 补丁描述实在太LOW。
>
> * 补丁格式不正确。
>
> * 补丁内容不正确。

下一节我们逐个解决这几个问题。但是首先我们应当将补丁回退。使用如下命令：

```sh
git reset HEAD~1
```

### 正确的PATCH

首先需要修改补丁描述。补丁第一行是标题，比较重要。它首先应当是模块名称。但是我们怎么找到 `drivers/clk/samsung/clk-s3c2412.c`文件属于哪个模块？可以试试下面这个命令，看看 `drivers/clk/samsung/clk-s3c2412.c` 文件的历史补丁：

```sh
root@ThinkPad-T440:/dimsum/git/kernel.next# git log drivers/clk/samsung/clk-s3c2412.c
commit 02c952c8f95fd0adf1835704db95215f57cfc8e6
Author:Martin Kaiser <martin@kaiser.cx>
Date:   Wed Jan 25 22:42:25 2017 +0100

clk: samsung:mark s3c...._clk_sleep_init() as __init 
```

ok，模块名称是 `clk:samsung`。下面是我为这个补丁添加的描述，其中第一行是标题：

```sh
clk: samsung: mark symbols static where possible for s3c2410
 
We get 1 warnings when building kernel withW=1:
/dimsum/git/kernel.next/drivers/clk/samsung/clk-s3c2410.c:363:13:warning: no previous prototype for 's3c2410_common_clk_init'[-Wmissing-prototypes]
 void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
 
In fact, this function is only used in thefile in which they are
declared and don't need a declaration, but can be made static.
So this patch marks these functions with 'static'.
```

这段描述是我从其他补丁中拷贝出来的，有几下几点需要注意：

* 标题中故意添加了“for s3c2410”，以区别于另外两个补丁
* “1 warnings”这个单词中，错误的使用了复数，这是因为复制的原因
* “/dimsum/git/kernel.next/”这个路径名与我的本地路径相关，不应当出现在补丁中
* 警告描述超过了80个字符，但是这是一个特例，这里允许超过80字符

这些问题，如果不处理的话，Maintainer会不高兴的！如果Maintainer表示了不满，而你不修正的话，这个补丁就会被忽略。

修正后的补丁描述如下：

```sh
clk: samsung: mark symbols static wherepossible for s3c2410
 
We get 1 warning when building kernel withW=1:
drivers/clk/samsung/clk-s3c2410.c:363:13:warning: no previous prototype for 's3c2410_common_clk_init'[-Wmissing-prototypes]
 void__init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
 
In fact, this function is only used in thefile in which they are
declared and don't need a declaration, but can be made static.
So this patch marks these functions with 'static'.
```

我们的补丁描述一定要注意用词，不要出现将“unused”写为“no used”这样的错误。反复使用 `git add`，`git commit` 将补丁提交到git仓库。

---

终于快成功，是不是想庆祝一下。用 git 命令看看我们刚才提交的三个补丁：

```sh
root@ThinkPad-T440:/dimsum/git/kernel.next#git log drivers/clk/samsung/
commit0539c5bc17247010d17394b0dc9f788959381c8f
Author: Baoyou Xie<baoyou.xie@linaro.org>
Date:  Thu Aug 17 20:43:09 2017 +0800
 
   clk: samsung: mark symbols static where possible for s3c2443
   
   We get 1 warning when building kernel with W=1:
   drivers/clk/samsung/clk-s3c2443.c:388:13: warning: no previous prototypefor 's3c2443_common_clk_init' [-Wmissing-prototypes]
    void __init s3c2443_common_clk_init(struct device_node *np, unsignedlong xti_f,
   
   In fact, this function is only used in the file in which they are
   declared and don't need a declaration, but can be made static.
   So this patch marks these functions with 'static'.
 
commitc231d40296b4ee4667e3559e34b00f738cae1e58
Author: Baoyou Xie<baoyou.xie@linaro.org>
Date:  Thu Aug 17 20:41:38 2017 +0800
 
   clk: samsung: mark symbols static where possible for s3c2412
   
   We get 1 warning when building kernel with W=1:
   drivers/clk/samsung/clk-s3c2412.c:254:13: warning: no previous prototypefor 's3c2412_common_clk_init' [-Wmissing-prototypes]
    void __init s3c2412_common_clk_init(struct device_node *np, unsignedlong xti_f,
   
   In fact, this function is only used in the file in which they are
   declared and don't need a declaration, but can be made static.
   So this patch marks these functions with 'static'.
 
commit ff8ea5ed4947d9a643a216d51f14f6cb87abcb97
Author: Baoyou Xie<baoyou.xie@linaro.org>
Date:  Thu Aug 17 20:40:50 2017 +0800
 
   clk: samsung: mark symbols static where possible for s3c2410
```

**但是，你发现补丁描述里面还有什么不正确的吗？？**不过Maintainer也许发现不了这个问题，最后这个补丁也可能被接收入内核。

下面我们生成补丁：

```sh
root@ThinkPad-T440:/dimsum/git/kernel.next#git format-patch -s -3
0001-clk-samsung-mark-symbols-static-where-possible-for-s.patch
0002-clk-samsung-mark-symbols-static-where-possible-for-s.patch
0003-clk-samsung-mark-symbols-static-where-possible-for-s.patch
```

实际上，我们的补丁仍然是错误的。在发送补丁前，我们需要用脚本检查一下补丁：

```sh
root@ThinkPad-T440:/dimsum/git/kernel.next#./scripts/checkpatch.pl 000*
---------------------------------------------------------------
0001-clk-samsung-mark-symbols-static-where-possible-for-s.patch
---------------------------------------------------------------
WARNING: Possible unwrapped commit description (prefer a maximum 75 chars per line)
#9:
 void__init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
 
WARNING: line over 80 characters
#29: FILE:drivers/clk/samsung/clk-s3c2410.c:363:
+static void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
 
total: 0 errors, 2 warnings, 8 lineschecked 
```

请留意输出警告，其中第一个警告是说我们的描述中，有过长的语句。前面已经提到，这个警告可以忽略。但是第二个警告提示我们代码行超过80个字符了。这是不能忽略的警告，必须处理。

使用 `git reset HEAD~3` 命令将三个补丁回退。重新修改代码：

```c
static void __init s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
```

修改为

```c
static void __init
s3c2410_common_clk_init(struct device_node *np, unsigned long xti_f,
```

重新提交补丁，并用 `git format-patch` 命令生成补丁。

## 2.4 发送PATCH

生成正确的补丁后，请再次用**checkpatch.pl**检查补丁正确性。确保无误后，可以准备将它发送给Maintainer了。但是应该将补丁发给谁？这可以用**get_maintainer.pl**来查看：

```sh
root@ThinkPad-T440:/dimsum/git/kernel.next#./scripts/get_maintainer.pl 000*
Kukjin Kim <kgene@kernel.org>(maintainer:ARM/SAMSUNG EXYNOS ARM ARCHITECTURES)
Krzysztof Kozlowski <krzk@kernel.org>(maintainer:ARM/SAMSUNG EXYNOS ARM ARCHITECTURES)
Sylwester Nawrocki<s.nawrocki@samsung.com> (supporter:SAMSUNG SOC CLOCK DRIVERS)
Tomasz Figa <tomasz.figa@gmail.com>(supporter:SAMSUNG SOC CLOCK DRIVERS)
Chanwoo Choi <cw00.choi@samsung.com>(supporter:SAMSUNG SOC CLOCK DRIVERS)
Michael Turquette<mturquette@baylibre.com> (maintainer:COMMON CLK FRAMEWORK)
Stephen Boyd <sboyd@codeaurora.org>(maintainer:COMMON CLK FRAMEWORK)
linux-arm-kernel@lists.infradead.org(moderated list:ARM/SAMSUNG EXYNOS ARM ARCHITECTURES)
linux-samsung-soc@vger.kernel.org (moderatedlist:ARM/SAMSUNG EXYNOS ARM ARCHITECTURES)
linux-clk@vger.kernel.org (open list:COMMONCLK FRAMEWORK)
linux-kernel@vger.kernel.org (open list)
```

接下来，可以用 `git send-email` 命令发送补丁了：

```sh
git send-email 000* --tokgene@kernel.org,krzk@kernel.org,s.nawrocki@samsung.com,tomasz.figa@gmail.com,cw00.choi@samsung.com,mturquette@baylibre.com,sboyd@codeaurora.org--cc linux-arm-kernel@lists.infradead.org,linux-samsung-soc@vger.kernel.org,linux-clk@vger.kernel.org,linux-kernel@vger.kernel.org
```

注意，哪些人应当作为邮件接收者，哪些人应当作为抄送者。在本例中，补丁是属于实验性质的，可以不抄送给邮件列表帐户。

> **提醒**：你应当将补丁先发给自己，检查无误后再发出去。如果你有朋友在社区有较高的威望，也可以抄送给他，必要的时候，也许他能给你一些帮助。这有助于将补丁顺利的合入社区。
>
> **重要提醒**：本文讲述的，主要是实验性质的补丁，用于打开社区大门。真正重要的补丁，可能需要经过反复修改，才能合入社区。我知道有一些补丁，超过两年时间都没能合入社区，因为总是有需要完善的地方，也许还涉及一些社区政治：）

# 3 如何在github上规范的提交PR

[如何在 Github 上规范的提交 PR（图文详解） - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/584834288)

[如何在github上提交PR(Pull Request)-腾讯云开发者社区-腾讯云 (tencent.com)](https://cloud.tencent.com/developer/article/1999727)

[如何参与开源项目 - 细说 GitHub 上的 PR 全过程 - 胡涛的个人网站 | Seven Coffee Cups (danielhu.cn)](https://www.danielhu.cn/open-a-pr-in-github/)

[Git工作流和核心原理 | GitHub基本操作 | VS Code里使用Git和关联GitHub_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV1r3411F7kn/?spm_id_from=333.788.top_right_bar_window_custom_collection.content.click&vd_source=e97ae8f8b8ae2ceb4dd6eec6f1e33ee9)

[给学完Git，还不会用GitHub的朋友们_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV1RC411W7UE/?spm_id_from=333.788.top_right_bar_window_custom_collection.content.click&vd_source=e97ae8f8b8ae2ceb4dd6eec6f1e33ee9)

---

## 3.1 如何参与开源项目？

### 寻找一个合适的开源项目

如果你就只是想开始参与开源，暂时还不知道该参与哪个社区，那么我有几个小建议：

1. **不要从特别成熟的项目开始**。比如现在去参与 Kubernetes 社区，一方面由于贡献者太多，很难抢到一个入门级的 issue 来开始第一个 PR；另外一方面也由于贡献者太多，你的声音会被淹没，社区维护者并不在意多你一个或者少你一个（当然可能没有人会承认，但是你不得不信），如果你提个 PR 都遇到了各种问题还不能自己独立解决，那么很可能你的 PR 会直接超时关闭，没有人在意你是不是有一个好的参与体验；
2. **不要从特别小的项目开始**。这就不需要我解释了吧？很早期的开源项目可能面临着非常多的问题，比如代码不规范、协作流程不规范、重构频繁且不是 issue 驱动的，让外部参与者无所适从……
3. **选择知名开源软件基金会的孵化项目**，这类项目一方面不是特别成熟，所以对新贡献者友好；另一方面也不会特别不成熟，不至于给人很差的参与体验，比如 **Apache 基金会、Linux 基金会、CNCF 等**。

### 寻找贡献点

开源项目的参与方式很多，最典型的方式是提交一个特性开发或者 bug 修复相关的 PR，但是其实文档完善、测试用例完善、bug 反馈等等也都是非常有价值的贡献。不过本文还是从需要提 PR 的贡献点开始上手，以 DevStream 项目为例（其他项目也一样），在项目 GitHub 代码库首页都会有一个 [Issues 入口](https://github.com/devstream-io/devstream/issues)，这里会记录项目目前已知的 bug、proposal(可以理解成新需求)、计划补充的文档、亟需完善的 UT 等等，如下图：

![img](https://www.danielhu.cn/open-a-pr-in-github/dtm-issues.png)

在 Issues 里我们一般可以找到一个“good first issue”标签标记的 issues，点击这个标签可以进一步直接筛选出所有的 good first issues，这是社区专门留给新贡献者的相对简单的入门级 issues：

![img](https://www.danielhu.cn/open-a-pr-in-github/dtm-good-first-issues.png)

没错，从这里开始，浏览一下这些 good first issues，看下有没有你感兴趣的而且还没被分配的 issue，然后在下面留言，等待项目管理员分配任务后就可以开始编码了，就像这样：

![img](https://www.danielhu.cn/open-a-pr-in-github/dtm-assign.png)

如图所示，如果一个 issue 还没有被认领，这时候你上去留个言，等待管理员会将这个任务分配给你，接着你就可以开始开发了。

## 3.2 如何提交PR？

一般开源项目代码库根目录都会有一个 CONTRIBUTING.md 或者其他类似名字的文档来介绍如何开始贡献。在 [DevStream 的 Contributing](https://github.com/devstream-io/devstream/blob/main/CONTRIBUTING.md) 文档里我们放了一个 [Development Workflow](https://github.com/devstream-io/devstream/blob/main/docs/development/development-workflow.md)，其实就是 PR 工作流的介绍，不过今天，我要更详细地聊聊 PR 工作流。

### step-1: Fork项目仓库

GitHub 上的项目都有一个 Fork 按钮，我们需要先将开源项目 fork 到自己的账号下，以 DevStream 为例：

![img](https://www.danielhu.cn/open-a-pr-in-github/fork.png)

点一下 Fork 按钮，然后回到自己账号下，可以找到 fork 到的项目了：

![img](https://www.danielhu.cn/open-a-pr-in-github/fork-2.png)

这个项目在你自己的账号下，也就意味着你有任意修改的权限了。我们后面要做的事情，就是将代码变更提到自己 fork 出来的代码库里，然后再通过 Pull Request 的方式将 commits 合入上游项目。

### step-2: 克隆项目仓库到本地

对于任意一个开源项目，流程几乎都是一样的。我直接写了一些命令，大家可以复制粘贴直接执行。当然，命令里的一些变量还是需要根据你自己的实际需求修改，比如对于 DevStream 项目，我们可以先这样配置几个**环境变量：**

```sh
export WORKING_PATH="~/gocode"
export USER="daniel-hutao"
export PROJECT="devstream"
export ORG="devstream-io"
```

同理对于 DevLake，这里的命令就变成了这样：

```sh
export WORKING_PATH="~/gocode"
export USER="daniel-hutao"
export PROJECT="incubator-devlake"
export ORG="apache"
```

记得 USER 改成你的 GitHub 用户名，WORKING_PATH 当然也可以灵活配置，你想把代码放到哪里，就写对应路径。

---

接着就是几行通用的命令来完成 clone 等操作了：

```sh
mkdir -p ${WORKING_PATH}
cd ${WORKING_PATH}
# You can also use the url: git@github.com:${USER}/${PROJECT}.git
# if your ssh configuration is proper
git clone https://github.com/${USER}/${PROJECT}.git
cd ${PROJECT}

git remote add upstream https://github.com/${ORG}/${PROJECT}.git
# Never push to upstream locally
git remote set-url --push upstream no_push
```

如果你配置好了 ssh 方式来 clone 代码，当然，git clone 命令用的 url 可以改成

```sh
git@github.com:${USER}/${PROJECT}.git
```

完成这一步后，我们在本地执行 `git remote -v`，看到的 remote 信息应该是这样的：

```sh
origin	git@github.com:daniel-hutao/devstream.git (fetch)
origin	git@github.com:daniel-hutao/devstream.git (push)
upstream	https://github.com/devstream-io/devstream (fetch)
upstream	no_push (push)
```

记住啰，你本地的代码变更永远只提交到 origin，然后通过 origin 提交 Pull Request 到 upstream。

### step-3: 更新本地分支代码

如果你刚刚完成 fork 和 clone 操作，那么你本地的代码肯定是新的。但是“刚刚”只存在一次，**接着每一次准备开始写代码之前，你都需要确认本地分支的代码是新的，**因为基于老代码开发你会陷入无限的冲突困境之中。你需要做以下两件事：

* **更新本地的 main 分支代码**

  ```sh
  git fetch upstream
  git checkout main
  git rebase upstream/main
  ```

  当然，我不建议你直接在 main 分支写代码，虽然你的第一个 PR 从 main 提交完全没有问题，但是如果你需要同时提交2个 PR 呢？总之建议新增一个 `feat-xxx` 或者 `fix-xxx` 等更可读的分支来完成开发工作。

* **创建分支**

  ```sh
  git checkout -b feat-xxx
  ```

  这样，我们就得到了一个和上游 main 分支代码一样的特性分支 feat-xxx 了，接着可以开始愉快地写代码啦！

### step-4: 写代码

改代码吧！

### step-5: add/commit/push

通用的流程如下：

```sh
git add <file>
git commit -s -m "some description here"
git push origin feat-xxx

Counting objects: 80, done.
Delta compression using up to 10 threads.
Compressing objects: 100% (74/74), done.
Writing objects: 100% (80/80), 13.78 KiB | 4.59 MiB/s, done.
Total 80 (delta 55), reused 0 (delta 0)
remote: Resolving deltas: 100% (55/55), completed with 31 local objects.
remote: 
remote: Create a pull request for 'feat-1' on GitHub by visiting:
remote:      https://github.com/daniel-hutao/devstream/pull/new/feat-1
remote: 
To github.com:daniel-hutao/devstream.git
 * [new branch]      feat-1 -> feat-1
```

当然，这里大家需要理解这几个命令和参数的含义，灵活调整。比如你也可以用 `git add --all` 完成 add 步骤，在 push 的时候也可以加 `-f` 参数，用来强制覆盖远程分支（假如已经存在，但是 commits 记录不合你意）。但是请记得 `git commit` 的 `-s` 参数一定要加哦！

到这里，本地 commits 就推送到远程了。

### step-6: 开一个PR

在完成 push 操作后，我们打开 GitHub，可以看到一个黄色的提示框，告诉我们可以开一个 Pull Request 了：

![img](https://www.danielhu.cn/open-a-pr-in-github/pushed.png)

如果你没有看到这个框，也可以直接切换到 feat-1 分支，然后点击下方的“Contribute”按钮来开启一个 PR，或者直接点 Issues 边上的 Pull requests 进入对应页面。Pull Request 格式默认是这样的：

![img](https://www.danielhu.cn/open-a-pr-in-github/pr.png)

这里我们需要填写一个合适的标题（默认和 commit message 一样），然后按照模板填写 PR 描述。PR 模板其实在每个开源项目里都不太一样，我们需要仔细阅读上面的内容，避免犯低级错误。

比如 DevStream 的模板里目前分为4个部分：

1. **Pre-Checklist**：这里列了3个前置检查项，提醒 PR 提交者要先阅读 Contributing 文档，然后代码要有完善的注释或者文档，尽可能添加测试用例等；
2. **Description**：这里填写的是 PR 的描述信息，也就是介绍你的 PR 内容的，你可以在这里描述这个 PR 解决了什么问题等；
3. **Related Issues**：记得吗？我们在开始写代码之前其实是需要认领 issue 的，这里要填写的也就是对应 issue 的 id，假如你领的 issue 链接是 https://github.com/devstream-io/devstream/issues/796，并且这个 issue 通过你这个 PR 的修改后就完成了，可以关闭了，这时候可以在 Related Issues 下面写“**close #796**”；
4. **New Behavior**：代码修改后绝大多数情况下是需要进行测试的，这时候我们可以在这里粘贴测试结果截图，这样 reviewers 就能够知道你的代码已经通过测试，功能符合预期，这样可以减少 review 工作量，快速合入。

这个模板并不复杂，我们直接对着填写就行。像这样：

![img](https://www.danielhu.cn/open-a-pr-in-github/pr-1.png)

然后点击右下角 `Create pull request` 就完成了一个 PR 的创建了。不过我这里不能去点这个按钮，我用来演示的修改内容没有意义，不能合入上游代码库。不过我还是想给你看下 PR 创建出来后的效果，我们以 [pr655](https://github.com/devstream-io/devstream/pull/655) 为例吧。

这是上个月我提的一个 PR，基本和模板格式一致。除了模板的内容，可能你已经注意到这里多了一个 Test 小节，没错，模板不是死的，模板只是为了降低沟通成本，你完全可以适当调整，只要结果是“往更清晰的方向走”的。我这里通过 Test 部分添加了本地详细测试结果记录，告诉 reviewers 我已经在本地充分测试了，请放心合入。

提交了 PR 之后，我们就可以在 PR 列表里找到自己的 PR 了，这时候还需要注意 ci 检查是不是全部能够通过，假如失败了，需要及时修复。以 DevStream 为例，ci 检查项大致如下：

![img](https://www.danielhu.cn/open-a-pr-in-github/ci.png)

### step-7: PR合入

如果你的 PR 很完美，毫无争议，那么过不了太长时间，项目管理员会直接合入你的 PR，那么你这个 PR 的生命周期也就到此结束了。

但是，没错，这里有个“但是”，但是往往第一次 PR 不会那么顺利，我们接下来就详细介绍一下可能经常遇到的一些问题和对应的解决办法。

## 3.3 提交PR可能遇到的问题

多数情况下，提交一个 PR 后是不会被马上合入的，reviewers 可能会提出各种修改意见，或者我们的 PR 本身存在一些规范性问题，或者 ci 检查就直接报错了，怎么解决呢？继续往下看吧。

### Q1: 基于Reviewer的意见更新PR

很多时候，我们提交了一个 PR 后，还需要继续追加 commit，比如提交后发现代码还有点问题，想再改改，或者 reviewers 提了一些修改意见，我们需要更新代码。

一般我们遵守一个约定：

* 在 review 开始之前，更新代码尽量不引入新的 commits 记录，也就是能合并就合并，保证 commits 记录清晰且有意义；
* 在 review 开始之后，针对 reviewers 的修改意见所产生的新 commit，可以不向前合并，这样能够让二次 review 工作更有针对性。

不过不同社区要求不一样，可能有的开源项目会**要求一个 PR 里只能包含一个 commit，**大家根据实际场景灵活判断即可。

说回如何更新 PR，我们只需要在本地继续修改代码，然后通过和第一个 commit 一样的步骤，执行这几个命令：

```sh
git add <file>
git commit -s -m "some description here"
git push origin feat-xxx
```

这时候别看 push 的是 origin 的 feat-xxx 分支，其实 GitHub 会帮你把新增的 commits 全部追加到一个未合入 PR 里去。没错，你只管不断 push，PR 会自动更新。

至于如何合并 commits，我们下一小节具体介绍。

### Q2: 合并多且混乱的Commits

很多情况下我们需要去合并 commits，比如你的第一个 commit 里改了100行代码，然后发现少改了1行，这时候又提交了一个 commit，那么第二个 commit 就太 “没意思” 了，我们需要合并一下。

比如我这里有2个同名的 commits，第二个 commit 其实只改了一个标点：

![img](https://www.danielhu.cn/open-a-pr-in-github/2commits.png)

这时候我们可以通过 rebase 命令来完成2个 commits 的合并：

```sh
git rebase -i HEAD~2
```

执行这个命令会进入一个编辑页面，默认是 vim 编辑模式，内容大致如下：

```sh
pick 3114c0f docs: just for test
pick 9b7d63b docs: just for test

# Rebase d640931..9b7d63b onto d640931 (2 commands)
#
# Commands:
# p, pick = use commit
# r, reword = use commit, but edit the commit message
# e, edit = use commit, but stop for amending
# s, squash = use commit, but meld into previous commit
# f, fixup = like "squash", but discard this commit's log message
# x, exec = run command (the rest of the line) using shell
# d, drop = remove commit
#
# These lines can be re-ordered; they are executed from top to bottom.
#
# If you remove a line here THAT COMMIT WILL BE LOST.
#
# However, if you remove everything, the rebase will be aborted.
```

我们需要把第二个 pick 改成 s，然后保存退出：

```sh
pick 3114c0f docs: just for test
s 9b7d63b docs: just for test
```

接着会进入第二个编辑页面：

```sh
# This is a combination of 2 commits.
# This is the 1st commit message:

docs: just for test

Signed-off-by: Daniel Hu <tao.hu@merico.dev>

# This is the commit message #2:

docs: just for test

Signed-off-by: Daniel Hu <tao.hu@merico.dev>

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
# ...
```

这是用来编辑合并后的 commit message 的，我们直接删掉多余部分，只保留这样几行：

```sh
docs: just for test

Signed-off-by: Daniel Hu <tao.hu@merico.dev>
```

接着同样是 vim 的保存退出操作，这时候可以看到日志：

```sh
[detached HEAD 80f5e57] docs: just for test
 Date: Wed Jul 6 10:28:37 2022 +0800
 1 file changed, 2 insertions(+)
Successfully rebased and updated refs/heads/feat-1.
```

这时候可以通过`git log`命令查看下 commits 记录是不是符合预期：

![img](https://www.danielhu.cn/open-a-pr-in-github/rebase.png)

好，我们在本地确认 commits 已经完成合并，这时候就可以继续推送到远程，让 PR 也更新掉：

```sh
git push -f origin feat-xxx
```

这里需要有一个 `-f` 参数来强制更新，合并了 commits 本质也是一种冲突，需要刷掉远程旧的 commits 记录。

### Q3: 解决PR冲突

冲突可以在线解决，也可能本地解决，我们逐个来看。

#### 在线解决冲突

我们要尽可能避免冲突，养成每次写代码前更新本地代码的习惯。不过，冲突不可能完全避免，有时候你的 PR 被阻塞了几天，可能别人改了同一行代码，还抢先被合入了，这时候你的 PR 就出现冲突了，类似这样（同样，此刻我不能真的去上游项目构造冲突，所以下面用于演示的冲突在我在自己的 repo 里）：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict.png)

每次看到这个页面都会让人觉得心头一紧。我们点击 `Resolve conflicts` 按钮，就可以看到具体冲突的内容了：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-1.png)

可以看到具体冲突的行了，接下来要做的就是解决冲突。我们需要删掉所有的 `<<<<<<<`、`>>>>>>>` 和 `=======` 标记，只保留最终想要的内容，如下：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-2.png)

接着点击右上角的“Mark as Resolved”：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-3.png)

最后点击“Commit merge”：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-4.png)

这样就完成冲突解决了，可以看到产生了一个新的 commit：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-resolved.png)

到这里，冲突就解决掉了。

#### 本地解决冲突

更多时候，我们需要在本地解决冲突，尤其是冲突太多，太复杂的时候。同样，我们构造一个冲突，这次尝试在本地解决冲突。

首先，可以在线看一下冲突的内容：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-10.png)

接着我们在本地执行：

```sh
# 先切回到 main 分支
git checkout main
# 拉取上游代码（实际场景肯定是和上游冲突，我们这里的演示环境其实是 origin）
git fetch upstream
# 更新本地 main（这里也可以用 rebase，但是 reset 不管有没有冲突总是会成功）
git reset --hard upstream/main
```

到这里，本地 main 分支就和远程(或者上游) main 分支代码完全一致了，然后我们要做的是将 main 分支的代码合入自己的特性分支，同时解决冲突。

```sh
git checkout feat-1
git rebase main
```

这时候会看到这样的日志：

```sh
First, rewinding head to replay your work on top of it...
Applying: docs: conflict test 1
Using index info to reconstruct a base tree...
M       README.md
Falling back to patching base and 3-way merge...
Auto-merging README.md
CONFLICT (content): Merge conflict in README.md
error: Failed to merge in the changes.
Patch failed at 0001 docs: conflict test 1
The copy of the patch that failed is found in: .git/rebase-apply/patch

Resolve all conflicts manually, mark them as resolved with
"git add/rm <conflicted_files>", then run "git rebase --continue".
You can instead skip this commit: run "git rebase --skip".
To abort and get back to the state before "git rebase", run "git rebase --abort".
```

我们需要解决冲突，直接打开 README.md，找到冲突的地方，直接修改。这里的改法和上一小节介绍的在线解决冲突没有任何区别，我就不赘述了。代码里同样只保留最终内容，然后继续 git 命令走起来：

![img](https://www.danielhu.cn/open-a-pr-in-github/conflict-resolved-2.png)

可能此时你并不放心，那就通过`git log`命令看一下 commits 历史记录吧：

![img](https://www.danielhu.cn/open-a-pr-in-github/commits-history.png)

这里的“conflict test 2”是我提交到 main 分支的记录，可以看到这个时间比“conflict test 1”还要晚了一些，但是它先合入了。我们在 rebase 操作后，这个记录在前，我们特性分支的“conflict test 1”在后，看起来很和谐，我们继续将这个变更推送到远程，这个命令已经出现很多次了：

```sh
git push -f origin feat-xxx
```

这时候我们再回到 GitHub 看 PR 的话，可以发现冲突已经解决了，并且没有产生多余的 commit 记录，也就是说这个 PR 的 commit 记录非常干净，好似冲突从来没有出现过：

![img](https://www.danielhu.cn/open-a-pr-in-github/1commit.png)

至于什么时候可以在线解决冲突，什么时候适合本地解决冲突，就看大家如何看待“**需不需要保留解决冲突的记录**”了，不同社区的理解不一样，可能特别成熟的开源社区会希望使用本地解决冲突方式，因为在线解决冲突产生的这条 merge 记录其实“没营养”。

### Q4: CI检查不过

#### commit-message问题修复

前面我们提到过 commit message 的规范，但是第一次提交 PR 的时候还是很容易出错，比如 `feat: xxx` 其实能通过 ci 检查，但是 `feat: Xxx` 就不行了。假设现在我们不小心提交了一个 PR，但是里面 commit 的 message 不规范，这时候怎么修改呢？

这个比较简单，直接执行：

```sh
git commit --amend
```

这条命令执行后就能进入编辑页面，随意更新 commit message 了。改完之后，继续 push：

```sh
git push -f origin feat-xxx
```

这样就能更新 PR 里的 commit message 了。

#### DCO(sign)问题修复

相当多的开源项目会要求所有合入的 commits 都包含一行类似这样的记录：

```sh
Daniel Hu <tao.hu@merico.dev>
```

所以 commit message 看起来会像这样：

```sh
feat: some description here
    
Signed-off-by: Daniel Hu <tao.hu@merico.dev>
```

这行信息相当于是对应 commit 的作者签名。要添加这样一行签名当然很简单，我们直接在 `git commit` 命令后面加一个 `-s` 参数就可以了，比如 `git commit -s -m "some description here"` 提交的 commit 就会带上你的签名。

但是如果如果你第一次提交的 PR 里忘记了在 commits 中添加 Signed-off-by 呢？这时候，如果对应开源项目配置了 [DCO 检查](https://wiki.linuxfoundation.org/dco)，那么你的 PR 就会在 ci 检查中被 “揪出来” 没有正确签名。

我们同样先构造一个没有加签名的 commit：

![img](https://www.danielhu.cn/open-a-pr-in-github/dco.png)

如果提了 PR，看到的效果是这样的：

![img](https://www.danielhu.cn/open-a-pr-in-github/dco-1.png)

我们看下如何解决，执行以下命令即可：

```sh
git commit -amend -s
```

这样一个简单的命令，就能直接在最近一个 commit 里加上 Signed-off-by 信息。执行这行命令后会直接进入 commit message 编辑页面，默认如下：

```sh
docs: dco test

Signed-off-by: Daniel Hu <tao.hu@merico.dev>
```

完成签名后呢？当然是来一个强制 push 了：

```sh
git push -f origin feat-xxx
```

这样，你 PR 中的 DCO 报错就自然修复了。













