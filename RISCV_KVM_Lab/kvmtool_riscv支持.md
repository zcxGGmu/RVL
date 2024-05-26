# 0 问题

- [ ] `2.3/4)/c` 中关于mp_state的处理有疑问，`KVM_MP_STATE_STOPPED` 最开始进入Guest前由谁来设置？





# 1 基于qemu/kvmtool运行riscv-guest





# 2 KVMTOOL

[KVM-api学习--基于kvmtool - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/545241171)

## 2.1 kvmtool流程梳理

使用以下命令即可启动一台虚拟机：

```sh
lkvm run --kernel ./vmlinuz-5.10.75-sunxi64 --disk ./ramdisk --name rzl-vm --cpus 1 --mem 512
```

* `run`: 启动一个虚拟机（VM） 
* `kernel`：VM的kernel
* `disk`：disk镜像或者rootfs目录（我这里是rootfs目录）
* `name`: Guest VM的名称
* `cpus`: 分配给虚拟机的CPU数量
* `mem`: 分配给VM的内存（单位为MiB）

以上就是一些基础的配置选项，接下来从这个 `run` 命令开始梳理kvmtool的代码流程：

```c
main
    +-> handle_kvm_command
   		+-> handle_command //kvm-cmd.c定义了kvm_commands数组，保存各种kvmtool命令的处理函数，run对应的是`kvm_cmd_run`
    		+-> kvm_cmd_run //builtin-run.c
    			+-> kvm_cmd_run_init //命令行解析与配置
    				+-> init_list__init // util/init.c
    					/*
    						KVMTOOL定义了一系列init宏，用来在main执行前将一系列初始化函数添加到函数链表init_lists中
    						在 include/kvm/util-init.h 中
    						
    						若函数被设定为constructor属性，则该函数会在main（）函数执行之前被自动的执行。
    						类似的，若函数被设定为destructor属性，则该函数会在main（）函数执行之后或者
    						exit（）被调用后被自动的执行。拥有此类属性的函数经常隐式的用在程序的初始化数据方面。
    						
    						遍历init_lists 链表，执行初始化函数进行初始化工作。
    						core_init(kvm__init);
    						base_init(kvm_cpu__init);
    						dev_init(plic__init);
    						dev_base_init(disk_image__init);
    						dev_base_init(pci__init);
    						virtio_dev_init(virtio_blk__init);
    						late_init(aia__init);
    					*/
    					+-> kvm__init
    						+-> kvm->sys_fd = open(kvm->cfg.dev, O_RDWR);
							+-> ret = ioctl(kvm->sys_fd, KVM_GET_API_VERSION, 0);
							+-> kvm->vm_fd = ioctl(kvm->sys_fd, KVM_CREATE_VM, kvm__get_vm_type(kvm));
							+-> kvm__check_extensions(kvm);
							+-> kvm__arch_init(kvm);
								/*
									riscv/kvm.c:
									mmap一块内存为VM使用，同时riscv__irqchip_create进行中断相关的初始化
									包括：	aia__create/plic__create,
								*/
                            +-> kvm__init_ram(kvm);
								+-> // 虚拟机地址空间的基本属性
                                    phys_start	= RISCV_RAM;      // guest系统内存的起始地址(gpa)
									phys_size	= kvm->ram_size;  // 内存大小
									host_mem	= kvm->ram_start; // hva的起始地址
								+-> kvm__register_ram(kvm, phys_start, phys_size, host_mem);
									+-> // kvmtool向kvm注册memory的过程，单独分析
							+-> if(!kvm->cfg.firmware_filename) //没设置固件的情况
								+-> kvm__load_kernel //加载kernel/DTB到指定位置处
                            +-> if (kvm->cfg.firmware_filename) //设置固件的情况
                                +-> kvm__load_firmware
                                +-> kvm__arch_setup_firmware
    					+-> kvm_cpu__init
                            +-> // 有一些确定vcpu的数量的工作
                            +-> kvm_cpu__arch_init
                                +-> // 创建、初始化vcpu的工作，单独分析
    			+-> kvm_cmd_run_work(kvm)
    				+-> //vcpu准备、运行、退出处理
    					for (i = 0; i < kvm->nrcpus; i++) {
                            if (pthread_create(&kvm->cpus[i]->thread, NULL, kvm_cpu_thread, kvm->cpus[i]) != 0)
                                die("unable to create KVM VCPU thread");
						}
						//...
						return kvm_cpu__exit(kvm); 
						--------------------------------
                        /* vcpu启动线程：kvm_cpu_thread */
                        kvm_cpu_thread
                           +-> kvm_cpu__start(current_kvm_cpu) //kvm-cpu.c
                               +-> kvm_cpu__reset_vcpu //ioctl(KVM_GET_MP_STATE)，将kernel/DTB的hva地址传递给KVM
                            	   +-> // riscv/kvm-cpu.c
                               +-> kvm_cpu__run
                            	   +-> ioctl(vcpu->vcpu_fd, KVM_RUN, 0);
                               +-> switch (cpu->kvm_run->exit_reason) 
                                   +-> KVM_EXIT_DEBUG:
                     				   kvm_cpu__show_registers(cpu);
									   kvm_cpu__show_code(cpu);
                                   +-> KVM_EXIT_IO:
									   ret = kvm_cpu__emulate_io(cpu,
                                                  cpu->kvm_run->io.port,
                                                  (u8 *)cpu->kvm_run +
                                                  cpu->kvm_run->io.data_offset,
                                                  cpu->kvm_run->io.direction,
                                                  cpu->kvm_run->io.size,
                                                  cpu->kvm_run->io.count);
								   +-> KVM_EXIT_MMIO:
									   kvm_cpu__handle_coalesced_mmio(cpu);
                                       ret = kvm_cpu__emulate_mmio(cpu,
                                                    cpu->kvm_run->mmio.phys_addr,
                                                    cpu->kvm_run->mmio.data,
                                                    cpu->kvm_run->mmio.len,
                                                    cpu->kvm_run->mmio.is_write);
    			+-> kvm_cmd_run_exit(kvm, ret) // 执行各种deinit
    				+-> compat__print_all_messages();
					+-> init_list__exit(kvm);
```

整体流程进一步简化为：

1. 使用 `ioctl KVM_CREATE_VM` 创建VM，此时VM还是一个空壳；
2. mmap一块内存，并通过 `ioctl KVM_SET_USER_MEMORY_REGION` 命令attach给 1 中创建好的VM；
3. 使用read函数将 kernel 读取到 2 中 mmap 好的内存中合适的位置；
4. 使用 `ioctl KVM_CREATE_VCPU` 创建一个vcpu；
5. 使用 `ioctl KVM_GET_VCPU_MMAP_SIZE` 获得 struct kvm_run 的大小并 mmap 到用户空间，以便获得vcpu的信息；
6. 使用 `ioctl KVM_ARM_VCPU_INIT` 命令初始化vcpu；
7. 为vcpu动态生成一些dts节点，比如timer等；
8. 调用 `ioctl KVM_RUN` 命令，VM开始跑起来；
9. 当KVM退出时，检查退出原因并进行相应的处理；

## 2.2 kvmtool数据结构

### 虚拟机整体相关

```c
struct kvm {
	struct kvm_arch		arch;
	struct kvm_config	cfg;
	int			sys_fd;		/* For system ioctls(), i.e. /dev/kvm */
	int			vm_fd;		/* For VM ioctls() */
	timer_t			timerid;	/* Posix timer for interrupts */

	int			nrcpus;		/* Number of cpus to run */
	struct kvm_cpu		**cpus;

	u32			mem_slots;	/* for KVM_SET_USER_MEMORY_REGION */
	u64			ram_size;	/* Guest memory size, in bytes */
	void			*ram_start;
	u64			ram_pagesize;
	struct mutex		mem_banks_lock;
	struct list_head	mem_banks;

	bool			nmi_disabled;
	bool			msix_needs_devid;

	const char		*vmlinux;
	struct disk_image       **disks;
	int                     nr_disks;

	int			vm_state;

#ifdef KVM_BRLOCK_DEBUG
	pthread_rwlock_t	brlock_sem;
#endif
};

struct kvm_arch {
	/*
	 * We may have to align the guest memory for virtio, so keep the
	 * original pointers here for munmap.
	 */
	void	*ram_alloc_start;
	u64	ram_alloc_size;

	/*
	 * Guest addresses for memory layout.
	 */
	u64	memory_guest_start;
	u64	kern_guest_start;
	u64	initrd_guest_start;
	u64	initrd_size;
	u64	dtb_guest_start;
};
```

### vcpu相关

```c
struct kvm_cpu {
	pthread_t	thread;

	unsigned long   cpu_id;

	unsigned long	riscv_xlen;
	unsigned long	riscv_isa;
	unsigned long	riscv_timebase;

	struct kvm	*kvm;
	int		vcpu_fd;
	struct kvm_run	*kvm_run;
	struct kvm_cpu_task	*task;

	u8		is_running;
	u8		paused;
	u8		needs_nmi;

	struct kvm_coalesced_mmio_ring	*ring;
};

/* for KVM_RUN, returned by mmap(vcpu_fd, offset=0) */
struct kvm_run {
    //...
    union {
        /* KVM_EXIT_RISCV_SBI */
		struct {
			unsigned long extension_id;
			unsigned long function_id;
			unsigned long args[6];
			unsigned long ret[2];
		} riscv_sbi;
		/* KVM_EXIT_RISCV_CSR */
		struct {
			unsigned long csr_num;
			unsigned long new_value;
			unsigned long write_mask;
			unsigned long ret_value;
		} riscv_csr;
    }
    
}

struct kvm_cpu_task {
	void (*func)(struct kvm_cpu *vcpu, void *data);
	void *data;
};

struct kvm_coalesced_mmio {
	__u64 phys_addr;
	__u32 len;
	union {
		__u32 pad;
		__u32 pio;
	};
	__u8  data[8];
};

struct kvm_coalesced_mmio_ring {
	__u32 first, last;
	struct kvm_coalesced_mmio coalesced_mmio[];
};

```

## 2.3 kvmtool虚拟机生命周期 (cpu/memory)

### 1) kvmtool初始化框架

首先需要说明的是，GNU `__attribute__` 机制可以设置函数属性（Function Attribute), 变量属性(Variable Attribute), 类型属性(Type Attribute)。它的基本语法如下所示：`__attribute__` (parameter)。

```c
#define __exit_list_add(cb, l)						\
static void __attribute__ ((constructor)) __init__##cb(void)		\
{									\
	static char name[] = #cb;					\
	static struct init_item t;					\
	exit_list_add(&t, cb, l, name);					\
}
```

**属性constructor/destructor：**若函数被设定为constructor属性，则该函数会在main 函数执行之前被自动的执行。类似的，若函数被设定为destructor属性，则该函数会在 main 函数执行之后或者 exit 被调用后被自动的执行。**拥有此类属性的函数经常隐式的用在程序的初始化数据方面。**

---

KVMTOOL定义了一系列 init 宏，用来将一系列初始化函数在main函数执行前，就添加到函数链表init_lists中。

```c
static struct hlist_head init_lists[PRIORITY_LISTS];

int init_list_add(struct init_item *t, int (*init)(struct kvm *),
			int priority, const char *name)
{
	t->init = init;
	t->fn_name = name;
	hlist_add_head(&t->n, &init_lists[priority]);

	return 0;
}

int init_list_add(struct init_item *t, int (*init)(struct kvm *),
			int priority, const char *name);

#define __init_list_add(cb, l)						\
static void __attribute__ ((constructor)) __init__##cb(void)		\
{									\
	static char name[] = #cb;					\
	static struct init_item t;					\
	init_list_add(&t, cb, l, name);					\
}

#define core_init(cb) __init_list_add(cb, 0)
#define base_init(cb) __init_list_add(cb, 2)
#define dev_base_init(cb)  __init_list_add(cb, 4)
#define dev_init(cb) __init_list_add(cb, 5)
#define virtio_dev_init(cb) __init_list_add(cb, 6)
#define firmware_init(cb) __init_list_add(cb, 7)
#define late_init(cb) __init_list_add(cb, 9)
#endif
```

这些init函数主要包括：

![img](https://pic1.zhimg.com/v2-94d8555ad1a122c5892529a7de5cc120_b.jpg)

在main函数中，KVMTOOL在完成命令行解析与配置后，会遍历init_lists 链表，执行初始化函数进行初始化工作，调用链如下：

```c
main
    +-> handle_kvm_command
    	+-> handle_command
    		+-> kvm_cmd_run
    			+-> kvm_cmd_run_init
    				+-> init_list__init
    
int init_list__init(struct kvm *kvm)
{
	unsigned int i;
	int r = 0;
	struct init_item *t;

	for (i = 0; i < ARRAY_SIZE(init_lists); i++)
		hlist_for_each_entry(t, &init_lists[i], n) {
			r = t->init(kvm);
			if (r < 0) {
				pr_warning("Failed init: %s\n", t->fn_name);
				goto fail;
			}
		}
    
fail:
	return r;
}
```

### 2) 虚拟机内存注册: kvm__init_ram

`kvm__init` 的流程在见2.1节，此处重点分析 `kvm_init_ram`，该函数主要负责在host侧分配虚拟机内存并将其注册给KVM。这相当于在机箱中安装内存。

其中 `kvm->ram_size` 是要安装的内存大小，该字段在 `kvm__arch_init` 中被初始化：

```c
void kvm__arch_init(struct kvm *kvm)
{
    /*
     * 分配客户机内存。我们必须将我们的缓冲区对齐到64K，
     * 以便与virtio-mmio的最大客户机页面大小相匹配。
     * 如果使用THP（透明大页），那么我们的最小对齐值变为巨页
     * 大小。巨页大小总是大于64K，所以让我们采用这个值。
     */
    //在Host侧位Guest申请内存，这段空间就是HVA
	kvm->ram_size = min(kvm->cfg.ram_size, (u64)RISCV_MAX_MEMORY(kvm));
	kvm->arch.ram_alloc_size = kvm->ram_size;
	if (!kvm->cfg.hugetlbfs_path)
		kvm->arch.ram_alloc_size += HUGEPAGE_SIZE;
	kvm->arch.ram_alloc_start = mmap_anon_or_hugetlbfs(kvm,
						kvm->cfg.hugetlbfs_path,
						kvm->arch.ram_alloc_size);

	if (kvm->arch.ram_alloc_start == MAP_FAILED)
		die("Failed to map %lld bytes for guest memory (%d)",
		    kvm->arch.ram_alloc_size, errno);
	//与virtio-mmio区间对齐，ram_alloc_start为原始指针，ram_start是对齐后的起始地址
	kvm->ram_start = (void *)ALIGN((unsigned long)kvm->arch.ram_alloc_start,
					SZ_2M);
	
    //建议内核优化内存访问和页面管理
	madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size,
		MADV_MERGEABLE);

	madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size,
		MADV_HUGEPAGE);

}
```

- 第一行`madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size, MADV_MERGEABLE);`的调用建议内核，标记由`kvm->arch.ram_alloc_start`开始、大小为`kvm->arch.ram_alloc_size`的内存区域可以合并（mergeable）。这通常用于启用KSM（Kernel SamePage Merging，内核同页合并），KSM是一种内存节省技术，它通过查找内容相同的内存页并将它们合并为一个来减少内存使用。
- 第二行`madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size, MADV_HUGEPAGE);`的调用向内核表明，同一个内存区域应被视为使用大页（huge pages）的候选者。大页（或巨型页）技术通过使用更大的内存页（例如2MB或1GB，而不是默认的4KB）来减少页面表项的数量，从而改善应用程序的性能，特别是在处理大量数据时。

> `madvise`函数的一般形式是：
>
> ```c
> int madvise(void *addr, size_t length, int advice);
> ```
>
> - `addr`是指向内存区域开始的指针。
> - `length`是内存区域的大小。
> - `advice`是一个标志，用于指示应用程序对这段内存的使用模式。
>
> 该函数允许应用程序给内核一个“建议”（advice），告诉内核它对这段内存的期望使用模式。内核可以根据这些信息来优化页面回收算法、页面合并或对这段内存的缓存策略等。使用`madvise`函数可以优化应用程序的性能和内存使用效率，但是它的效果和是否被采纳依赖于操作系统的实现和当前的系统状态。

---

接下来，看 `kvm__init_ram`：

```c
#define RISCV_RAM		0x80000000ULL

void kvm__init_ram(struct kvm *kvm)
{
	int err;
	u64 phys_start, phys_size;
	void *host_mem;

	phys_start	= RISCV_RAM;		//Guest的物理内存起始地址(GPA)
	phys_size	= kvm->ram_size;	//Guest物理内存的大小
	host_mem	= kvm->ram_start;	//Host中为Guest内存分配的空间(HVA)

    //为Guest注册一个内存区域, 物理地址是[RISCV_RAM, RISCV_RAM + kvm->ram_size)
	err = kvm__register_ram(kvm, phys_start, phys_size, host_mem);
	if (err)
		die("Failed to register %lld bytes of memory at physical "
		    "address 0x%llx [err %d]", phys_size, phys_start, err);

	kvm->arch.memory_guest_start = phys_start;
}
```

---

`kvm__register_ram` 负责注册 `KVM_MEM_TYPE_RAM` 类型的内存, 如下：

```c
enum kvm_mem_type {
    KVM_MEM_TYPE_RAM = 1 << 0,  //普通随机访问内存, 也就通常理解的内存
    KVM_MEM_TYPE_DEVICE = 1 << 1,    //设备的板载内存
    KVM_MEM_TYPE_RESERVED = 1 << 2,
    KVM_MEM_TYPE_READONLY = 1 << 3, //只读
    
    KVM_MEM_TYPE_ALL	= KVM_MEM_TYPE_RAM
            | KVM_MEM_TYPE_DEVICE
            | KVM_MEM_TYPE_RESERVED
            | KVM_MEM_TYPE_READONLY
};

static inline int kvm__register_ram(struct kvm* kvm, u64 guest_phys, u64 size, void* userspace_addr)
{
    return kvm__register_mem(kvm, guest_phys, size, userspace_addr, KVM_MEM_TYPE_RAM);
}
```

再往下走，`kvm__register_mem` 负责为Guest注册一片内存区域，可以理解为向主板上某一个插槽插入一条内存(实际为Guest中一片内存区域)。**注册分为两部分：**

- 首先kvmtool自身需要管理Guest的物理内存, 每部分内存用 `struct kvm_mem_bank` 表示，所有的内存区域组织为一个链表，链表头为 `kvm->mem_banks`；
- 之后需要通过KVM为Guest添加一条内存，只有这样Guest才能开始使用这片内存. 这部分可以看KVM的api；

```c
/*
    [guest_phys, guest_phys+size)为Guest的物理地址范围
    userspace_addr为Host中为这部分内存分配的空间
    type表示内存属性
*/
int kvm__register_mem(struct kvm* kvm, u64 guest_phys, u64 size, void* userspace_addr, enum kvm_mem_type type)
{
    struct kvm_userspace_memory_region mem;
    struct kvm_mem_bank* merged = NULL;
    struct kvm_mem_bank* bank;
    struct list_head* prev_entry;
    u32 slot;
    u32 flags = 0;
    int ret;

    mutex_lock(&kvm->mem_banks_lock);   //内存条链表上锁

    /* 检查是否有重叠的内存区域, 并找到第一个空的内存插槽, 暂时不管 */
    slot = 0;
    prev_entry = &kvm->mem_banks;
    ...;

    //新建一个bank并初始化, bank表示一个内存区域
    bank = malloc(sizeof(*bank));
    INIT_LIST_HEAD(&bank->list);  //初始化链表元素
    bank->guest_phys_addr = guest_phys; //guest中这条内存的起始地址(GPA)
    bank->host_addr = userspace_addr;   //Host为这条内存分配的地址(HVA)
    bank->size = size;  //内存大小
    bank->type = type;  //内存类型
    bank->slot = slot;  //这个内存条对应的插槽

    if (type & KVM_MEM_TYPE_READONLY)   //是否只读
        flags |= KVM_MEM_READONLY;

    //通过KVM添加到Guest的物理内存中
    if (type != KVM_MEM_TYPE_RESERVED) {
        //根据该内存条初始化一个struct kvm_userspace_memory_region
        mem = (struct kvm_userspace_memory_region) {  
            .slot = slot,
            .flags = flags,
            .guest_phys_addr = guest_phys,
            .memory_size = size,
            .userspace_addr = (unsigned long)userspace_addr,
        };

        //告诉KVM为Guest添加一个内存条
        ret = ioctl(kvm->vm_fd, KVM_SET_USER_MEMORY_REGION, &mem);
    }

    list_add(&bank->list, prev_entry);  //把这个内存条添加到链表中
    kvm->mem_slots++;   //内存插槽++
    ret = 0;

out:
    mutex_unlock(&kvm->mem_banks_lock);
    return ret;
}
```

### 3) 加载内核与初始文件系统: kvm__load_kernel

内存注册好后，kvmtool还需要将内核以及初始文件系统加载至内存中的指定位置，代码如下：

```c
int kvm__init(struct kvm *kvm) {
    //...
    kvm__arch_init(kvm);

	INIT_LIST_HEAD(&kvm->mem_banks);
	kvm__init_ram(kvm);
    
   	if (!kvm->cfg.firmware_filename) {
		if (!kvm__load_kernel(kvm, kvm->cfg.kernel_filename,
				kvm->cfg.initrd_filename, kvm->cfg.real_cmdline))
			die("unable to load kernel %s", kvm->cfg.kernel_filename);
	}

	if (kvm->cfg.firmware_filename) {
		if (!kvm__load_firmware(kvm, kvm->cfg.firmware_filename))
			die("unable to load firmware image %s: %s", kvm->cfg.firmware_filename, strerror(errno));
	} else {
		ret = kvm__arch_setup_firmware(kvm);
		if (ret < 0)
			die("kvm__arch_setup_firmware() failed with error %d\n", ret);
	}
    
    //...
}

// riscv/kvm.c
bool kvm__load_firmware(struct kvm *kvm, const char *firmware_filename)
{
	/* TODO: Firmware loading to be supported later. */
	return false;
}

int kvm__arch_setup_firmware(struct kvm *kvm)
{
	return 0;
}
```

目前kvmtool没有单独实现固件设置/加载的逻辑，所以直接看 `kvm__load_kernel`：

```c
bool kvm__load_kernel(struct kvm *kvm, const char *kernel_filename,
		const char *initrd_filename, const char *kernel_cmdline)
{
	bool ret;
	int fd_kernel = -1, fd_initrd = -1;

	fd_kernel = open(kernel_filename, O_RDONLY);  //打开内核文件
	if (fd_kernel < 0)
		die("Unable to open kernel %s", kernel_filename);

	if (initrd_filename) {
		fd_initrd = open(initrd_filename, O_RDONLY);  //打开初始文件系统
		if (fd_initrd < 0)
			die("Unable to open initrd %s", initrd_filename);
	}

    //加载kernel和initrd到内存中, kernel_cmdline是内核启动时传递的命令
	ret = kvm__arch_load_kernel_image(kvm, fd_kernel, fd_initrd,
					  kernel_cmdline);
	
    //关闭文件
	if (initrd_filename)
		close(fd_initrd);
	close(fd_kernel);

	if (!ret)
		die("%s is not a valid kernel image", kernel_filename);
	return ret;
}
```

重点看 `kvm__arch_load_kernel_image`：

```c
#define FDT_ALIGN	SZ_4M
#define INITRD_ALIGN	8
bool kvm__arch_load_kernel_image(struct kvm *kvm, int fd_kernel, int fd_initrd,
				 const char *kernel_cmdline)
{
	void *pos, *kernel_end, *limit;
	unsigned long guest_addr, kernel_offset;
	ssize_t file_size;

	/*
	 * Linux requires the initrd and dtb to be mapped inside lowmem,
	 * so we can't just place them at the top of memory.
	 */
	limit = kvm->ram_start + min(kvm->ram_size, (u64)SZ_256M) - 1;

#if __riscv_xlen == 64
	/* Linux expects to be booted at 2M boundary for RV64 */
	kernel_offset = 0x200000;
#else
	/* Linux expects to be booted at 4M boundary for RV32 */
	kernel_offset = 0x400000;
#endif
	
    //放置kernel镜像
	pos = kvm->ram_start + kernel_offset;
	kvm->arch.kern_guest_start = host_to_guest_flat(kvm, pos); 	  // HVA -> GPA
	file_size = read_file(fd_kernel, pos, limit - pos); 		  // 读内核镜像到指定位置
	if (file_size < 0) {
		if (errno == ENOMEM)
			die("kernel image too big to fit in guest memory.");

		die_perror("kernel read");
	}
	kernel_end = pos + file_size;
	pr_debug("Loaded kernel to 0x%llx (%zd bytes)",
		 kvm->arch.kern_guest_start, file_size);

	/* Place FDT just after kernel at FDT_ALIGN address */
    //放置设备树FDT文件
	pos = kernel_end + FDT_ALIGN;
	guest_addr = ALIGN(host_to_guest_flat(kvm, pos), FDT_ALIGN);
	pos = guest_flat_to_host(kvm, guest_addr);
	if (pos < kernel_end)
		die("fdt overlaps with kernel image.");

	kvm->arch.dtb_guest_start = guest_addr;
	pr_debug("Placing fdt at 0x%llx - 0x%llx",
		 kvm->arch.dtb_guest_start,
		 host_to_guest_flat(kvm, limit));

	/* ... and finally the initrd, if we have one. */
	//放置initrd根文件系统
    if (fd_initrd != -1) {
		struct stat sb;
		unsigned long initrd_start;
		
        //获取initrd文件的大小等信息
		if (fstat(fd_initrd, &sb))
			die_perror("fstat");
		
        //计算放置initrd的位置，确保它位于内存的某个限制limit之前，并且按照INITRD_ALIGN（initrd对齐要求）对齐
		pos = limit - (sb.st_size + INITRD_ALIGN);
		guest_addr = ALIGN(host_to_guest_flat(kvm, pos), INITRD_ALIGN);
		pos = guest_flat_to_host(kvm, guest_addr);
		if (pos < kernel_end)
			die("initrd overlaps with kernel image.");

		initrd_start = guest_addr;
        //读initrd到内存指定位置
		file_size = read_file(fd_initrd, pos, limit - pos);
		if (file_size == -1) {
			if (errno == ENOMEM)
				die("initrd too big to fit in guest memory.");

			die_perror("initrd read");
		}

		kvm->arch.initrd_guest_start = initrd_start;
		kvm->arch.initrd_size = file_size;
		pr_debug("Loaded initrd to 0x%llx (%llu bytes)",
			 kvm->arch.initrd_guest_start,
			 kvm->arch.initrd_size);
	} else {
		kvm->arch.initrd_size = 0;
	}

	return true;
}
```

整体流程就是将 `kernel/FDT/initrd` 这些文件依次加载到内存的指定位置上，此过程中每个文件的起始地址都要按规则对齐，再通过 `host_to_guest_flat(kvm, pos)` 函数得到客户机地址GPA，kvmtool需要记录这些信息并将它们传递给KVM。

---

至此，`kvm__init` 函数也就结束了，主要涉及虚拟机全局的一些设置：比如内存、中断、内核镜像/设备树/根文件系统的加载等。但真正让虚拟机运行起来的，或者说描述虚拟机运行状态的软件抽象此时还未创建、初始化，这就是 `vcpu`。 

### 4) vcpu创建/初始化: kvm_cpu__arch_init

除了上面的 `kvm__init`，`init_list__init()` 还会调用众多其他初始化函数，比如PCI初始化, ioport初始化等等。我们先只关注 `kvm_cpu__init`，因为之前已经完成了内存的初始化，再加上CPU，那么虚拟机大体就可以跑起来了，具体的设备实现留到后面再分析。

#### a. vcpu创建以及初始化: kvm_cpu_init

`kvm_cpu__init()` 计算出Guest需要多少个CPU，申请cpu指针数组后再调用 `kvm_cpu__arch_init()` 构造一个CPU对象：

```c
static int task_eventfd;  

int kvm_cpu__init(struct kvm* kvm)
{
    int max_cpus, recommended_cpus, i;
	
    //最大CPU数量: ioctl(kvm->sys_fd, KVM_CHECK_EXTENSION, KVM_CAP_MAX_VCPUS);
    max_cpus = kvm__max_cpus(kvm);
    if (kvm->cfg.nrcpus > max_cpus) {
        kvm->cfg.nrcpus = max_cpus;
    }

    kvm->nrcpus = kvm->cfg.nrcpus;    //使用多少个CPU

    task_eventfd = eventfd(0, 0);     //创建一个事件描述符

    /* 分配CPU指针数组, 多申请一个用作末尾的NULL指针 */
    kvm->cpus = calloc(kvm->nrcpus + 1, sizeof(void*));

    //初始化每一个CPU
    for (i = 0; i < kvm->nrcpus; i++) {
        kvm->cpus[i] = kvm_cpu__arch_init(kvm, i);
    }

    return 0;
    ...;    //错误处理
}
base_init(kvm_cpu__init);
```

vcpu对应Host中的一个普通线程，kvmtools使用 `struct kvm_cpu` 表示一个vcpu, 主要字段如下：

```c
struct kvm_cpu {
	pthread_t	thread;

	unsigned long   cpu_id;

	unsigned long	riscv_xlen;
	unsigned long	riscv_isa;
	unsigned long	riscv_timebase;

	struct kvm	*kvm;
	int		vcpu_fd;
	struct kvm_run	*kvm_run;
	struct kvm_cpu_task	*task;

	u8		is_running;
	u8		paused;
	u8		needs_nmi;

	struct kvm_coalesced_mmio_ring	*ring;
};
```

---

调用 `kvm_cpu__arch_init` 创建、初始化vcpu：

```c
struct kvm_cpu *kvm_cpu__arch_init(struct kvm *kvm, unsigned long cpu_id)
{
	struct kvm_cpu *vcpu;
	u64 timebase = 0;
	unsigned long isa = 0, id = 0;
	unsigned long masks[KVM_REG_RISCV_SBI_MULTI_REG_LAST + 1] = { 0 };
	int i, coalesced_offset, mmap_size;
	struct kvm_one_reg reg;

	vcpu = calloc(1, sizeof(struct kvm_cpu));
	if (!vcpu)
		return NULL;

    //创建vcpu
	vcpu->vcpu_fd = ioctl(kvm->vm_fd, KVM_CREATE_VCPU, cpu_id);
	if (vcpu->vcpu_fd < 0)
		die_perror("KVM_CREATE_VCPU ioctl");

    //获取vcpu-isa
	reg.id = RISCV_CONFIG_REG(isa);
	reg.addr = (unsigned long)&isa;
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (config.isa)");
	
    //获取vtime
	reg.id = RISCV_TIMER_REG(frequency);
	reg.addr = (unsigned long)&timebase;
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (timer.frequency)");

    
	mmap_size = ioctl(kvm->sys_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < 0)
		die_perror("KVM_GET_VCPU_MMAP_SIZE ioctl");

    //映射vcpu->kvm_run共享内存，用于在host侧处理guest异常
	vcpu->kvm_run = mmap(NULL, mmap_size, PROT_RW, MAP_SHARED,
			     vcpu->vcpu_fd, 0);
	if (vcpu->kvm_run == MAP_FAILED)
		die("unable to mmap vcpu fd");

    //？？？
	coalesced_offset = ioctl(kvm->sys_fd, KVM_CHECK_EXTENSION,
				 KVM_CAP_COALESCED_MMIO);
	if (coalesced_offset)
		vcpu->ring = (void *)vcpu->kvm_run +
			     (coalesced_offset * PAGE_SIZE);

    //设置vcpu-isa
	reg.id = RISCV_CONFIG_REG(isa);
	reg.addr = (unsigned long)&isa;
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die("KVM_SET_ONE_REG failed (config.isa)");

    //cpu厂商相关
	if (kvm->cfg.arch.custom_mvendorid) {
		id = kvm->cfg.arch.custom_mvendorid;
		reg.id = RISCV_CONFIG_REG(mvendorid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.mvendorid)");
	}

    //设置marchid
	if (kvm->cfg.arch.custom_marchid) {
		id = kvm->cfg.arch.custom_marchid;
		reg.id = RISCV_CONFIG_REG(marchid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.marchid)");
	}

    //mimpid
	if (kvm->cfg.arch.custom_mimpid) {
		id = kvm->cfg.arch.custom_mimpid;
		reg.id = RISCV_CONFIG_REG(mimpid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.mimpid)");
	}

    //SBI
	for (i = 0; i < KVM_RISCV_SBI_EXT_MAX; i++) {
		if (!kvm->cfg.arch.sbi_ext_disabled[i])
			continue;
		masks[KVM_REG_RISCV_SBI_MULTI_REG(i)] |=
					KVM_REG_RISCV_SBI_MULTI_MASK(i);
	}
	for (i = 0; i <= KVM_REG_RISCV_SBI_MULTI_REG_LAST; i++) {
		if (!masks[i])
			continue;

		reg.id = RISCV_SBI_EXT_REG(KVM_REG_RISCV_SBI_MULTI_DIS, i);
		reg.addr = (unsigned long)&masks[i];
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (sbi_ext %d)", i);
	}

	/* Force enable SBI debug console if not disabled from command line */
	if (!kvm->cfg.arch.sbi_ext_disabled[KVM_RISCV_SBI_EXT_DBCN]) {
		id = 1;
		reg.id = RISCV_SBI_EXT_REG(KVM_REG_RISCV_SBI_SINGLE,
					   KVM_RISCV_SBI_EXT_DBCN);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			pr_warning("KVM_SET_ONE_REG failed (sbi_ext %d)",
				   KVM_RISCV_SBI_EXT_DBCN);
	}

	/* Populate the vcpu structure. */
	vcpu->kvm		= kvm;
	vcpu->cpu_id		= cpu_id;
	vcpu->riscv_isa		= isa;
	vcpu->riscv_xlen	= __riscv_xlen;
	vcpu->riscv_timebase	= timebase;
	vcpu->is_running	= true;

	return vcpu;
}
```

* `isa/timebase`

  https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/api.rst#L2752，硬件上的真实寄存器只有一套，我们需要为在riscv hart上运行的每个vcpu都维护一套独立的状态，同时虚拟机应该和物理机拥有相同的寄存器视图。`KVM_GET_ONE_REG/KVM_SET_ONE_REG` 是KVM提供给用户态工具的获取/设置任意寄存器的接口，这么多寄存器总得有一个flag与每个寄存器进行对应否则怎么区分？这就是 `kvm_one_reg` 的 id 字段，这个 `reg->id` 和硬件架构无关，是KVM纯软件层面的协议，与KVM对接的用户态工具也需要遵循它来写代码。

  ```c
  struct kvm_one_reg {
  	__u64 id;
  	__u64 addr;
  };
  
  reg.id = RISCV_CONFIG_REG(isa);
  reg.addr = (unsigned long)&isa;
  if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
      die("KVM_GET_ONE_REG failed (config.isa)");
  
  #define RISCV_CONFIG_REG(name)	__kvm_reg_id(KVM_REG_RISCV_CONFIG, 0, \
  					     KVM_REG_RISCV_CONFIG_REG(name), \
  					     KVM_REG_SIZE_ULONG)
  --------------------------------------------------------------------------
  #define KVM_REG_RISCV		0x8000000000000000ULL
  static inline __u64 __kvm_reg_id(__u64 type, __u64 subtype,
  				 __u64 idx, __u64  size)
  {
  	return KVM_REG_RISCV | type | subtype | idx | size;
  }
  /* Config registers are mapped as type 1 */
  #define KVM_REG_RISCV_CONFIG		(0x01 << KVM_REG_RISCV_TYPE_SHIFT)
  #define KVM_REG_RISCV_CONFIG_REG(name)	\
  	(offsetof(struct kvm_riscv_config, name) / sizeof(unsigned long))
  
  /* KVM */
  int kvm_riscv_vcpu_get_reg(struct kvm_vcpu *vcpu,
  			   const struct kvm_one_reg *reg)
  {
  	switch (reg->id & KVM_REG_RISCV_TYPE_MASK) {
  	case KVM_REG_RISCV_CONFIG:
  		return kvm_riscv_vcpu_get_reg_config(vcpu, reg);
  	case KVM_REG_RISCV_TIMER:
  		return kvm_riscv_vcpu_get_reg_timer(vcpu, reg);
     	}
      
      //...
  }
  
  #define KVM_REG_RISCV_TYPE_SHIFT	24
  /* Config registers are mapped as type 1 */
  #define KVM_REG_RISCV_CONFIG		(0x01 << KVM_REG_RISCV_TYPE_SHIFT)
  ```

* `KVM_CAP_COALESCED_MMIO`

  "coalesced_memory" 这种方式所仿真的 MMIO 会被 KVM 内核截取，但 KVM 并不会立即跳出到 qemu-kvm 用户空间，KVM 将需要仿真的读写操作形成一个记录 (`struct kvm_coalesced_mmio`)， 放在在代表整个VM的 `struct kvm` 所指向的一个环形缓冲区中 ( `struct kvm_coalesced_mmio_ring`)， 这个环形缓冲区被 mmap 到了用户空间。 

  当下一次代表某个 VCPU 的 qemu-kvm 线程返回到用户空间后，就会对环形缓冲区中的记录进行处理，执行 MMIO 读写仿真。 也就是说，对于 “coalesced_memory” 方式， qemu-kvm 一次仿真的可能是已经被积累起来的多个 MMIO 读写操作， 显然这种方式是一种性能优化，它适合于对响应时间要求不是很严格的 MMIO 写操作。

#### b. vcpu运行: kvm_cmd_run_work

在 `init_list__init` 执行完所有初始化函数后, 会一路返回到 `kvm_cmd_run()` 中, 进入 `kvm_cmd_run_work()` 开始虚拟机的执行：

```c
int kvm_cmd_run(int argc, const char** argv, const char* prefix)
{
    int ret = -EFAULT;
    struct kvm* kvm;

    //根据参数初始化一个kvm对象
    kvm = kvm_cmd_run_init(argc, argv);
    //执行一个虚拟机
    ret = kvm_cmd_run_work(kvm);
    //虚拟机退出
    kvm_cmd_run_exit(kvm, ret);
    return ret;
}
```

`kvm_cmd_run_work()` 为每一个vcpu创建一个线程并开始执行，然后等待 `CPU #0` 执行完毕, 至此kvmtool主线程挂起, 变成多个vcpu线程执行：

```c
static int kvm_cmd_run_work(struct kvm *kvm)
{
	int i;
	
    //为每一个vcpu创建一个线程, 执行kvm_cpu_thread(kvm->cpus[i])
	for (i = 0; i < kvm->nrcpus; i++) {
		if (pthread_create(&kvm->cpus[i]->thread, NULL, kvm_cpu_thread, kvm->cpus[i]) != 0)
			die("unable to create KVM VCPU thread");
	}

	/* Only VCPU #0 is going to exit by itself when shutting down */
    //关机时只有VCPU #0会自己退出, 因此只需要等待这一个线程即可
	if (pthread_join(kvm->cpus[0]->thread, NULL) != 0)
		die("unable to join with vcpu 0");

	return kvm_cpu__exit(kvm);
}
```

`kvm_cpu_thread` 在设置线程名后，调用 `kvm_cpu__start` 开始vcpu的执行，整体上是一个 `trap-emul` 的循环：

```c
int kvm_cpu__start(struct kvm_cpu* cpu)
{
    sigset_t sigset;

    ...;    //信号处理相关

    //重置CPU状态
    kvm_cpu__reset_vcpu(cpu);
    
    //CPU循环
    while (cpu->is_running) {
        //通知KVM开始cpu的执行
        kvm_cpu__run(cpu);

        //处理虚拟机退出原因
        switch (cpu->kvm_run->exit_reason) {
            case KVM_EXIT_IO: { //因为IO端口引发的vmexit
                ...;
            }
            case KVM_EXIT_MMIO: {
                ...;
            }
            case ...;
        }
        kvm_cpu__handle_coalesced_mmio(cpu);
    }
exit_kvm:
    return 0;
}
```

`kvm_cpu__start` 初始化vcpu寄存器后，会调用 `kvm_cpu__run` 函数开启vcpu的运行，该函数会通过 `ioctl(vcpu->vcpu_fd, KVM_RUN, 0)`通知KVM开始运行vcpu, KVM随后通过 `sret` 指令返回Guest, 而 `ioctl(KVM_RUN, ...)` 会被一直阻塞, 直到必须由kvmtool介入为止 (因为有些VM_EXIT在内核中就可以处理)，而后kvmtool会处理虚拟机退出, 然后继续开始vcpu的运行。

```c
void kvm_cpu__run(struct kvm_cpu* vcpu)
{
    int err;
    if (!vcpu->is_running)
        return;
    err = ioctl(vcpu->vcpu_fd, KVM_RUN, 0);
    if (err < 0 && (errno != EINTR && errno != EAGAIN))
        die_perror("KVM_RUN failed");
}
```

---

之前在 `kvm_cpu__arch_init` 函数中设置了一些基本vcpu寄存器，在vcpu运行这部分代码中也会进行一些vcpu寄存器设置工作，在 `kvm_vcpu__reset_vcpu` 函数中。

#### c. vcpu寄存器设置: kvm_vcpu__reset_vcpu

```c
void kvm_cpu__reset_vcpu(struct kvm_cpu *vcpu)
{
	struct kvm *kvm = vcpu->kvm;
	struct kvm_mp_state mp_state;
	struct kvm_one_reg reg;
	unsigned long data;

	if (ioctl(vcpu->vcpu_fd, KVM_GET_MP_STATE, &mp_state) < 0)
		die_perror("KVM_GET_MP_STATE failed");

    /*
     * 如果MP状态为停止，那么这意味着Linux KVM RISC-V模拟了
     * SBI v0.2（或更高版本）的HART电源管理，并且指定的VCPU
     * 将在启动时由引导VCPU进行启动。对于这样的VCPU，我们
     * 不在这里更新PC, A0和A1。？？？
     */
	if (mp_state.mp_state == KVM_MP_STATE_STOPPED)
		return;

	reg.addr = (unsigned long)&data;

	data	= kvm->arch.kern_guest_start;
	reg.id	= RISCV_CORE_REG(regs.pc);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (pc)");

	data	= vcpu->cpu_id;
	reg.id	= RISCV_CORE_REG(regs.a0);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (a0)");

	data	= kvm->arch.dtb_guest_start;
	reg.id	= RISCV_CORE_REG(regs.a1);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (a1)");
}
```

* `KVM_GET_MP_STATE`

  > [Documentation](https://elixir.bootlin.com/linux/latest/source/Documentation)/[virt](https://elixir.bootlin.com/linux/latest/source/Documentation/virt)/[kvm](https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm)/[api.rst](https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/api.rst)
  >
  > For riscv:
  > ^^^^^^^^^^
  >
  > The only states that are valid are KVM_MP_STATE_STOPPED and
  > KVM_MP_STATE_RUNNABLE which reflect if the vcpu is paused or not.

  ```c
  int kvm_arch_vcpu_ioctl_get_mpstate(struct kvm_vcpu *vcpu,
  				    struct kvm_mp_state *mp_state)
  {
  	if (vcpu->arch.power_off)
  		mp_state->mp_state = KVM_MP_STATE_STOPPED;
  	else
  		mp_state->mp_state = KVM_MP_STATE_RUNNABLE;
  
  	return 0;
  }
  ```

## 2.4 kvmtool处理虚拟机退出

虚拟机内部执行敏感指令，对riscv来说大致上分为几类：

* KVM可能配置了 `hstatus/status`，导致VS模式下Guest执行一些特殊指令将陷出，比如fp/vector指令等；
* SBI from VS-Mode，因为虚拟机不感知KVM的存在，其操作系统运行过程中依然会向M模式固件请求SBI服务，这被riscv h扩展标记为一种新的异常类型，因此也会导致Guest陷出；
* MMIO访问，对应的就是虚拟机访问页错误异常，Guest陷出后进行模拟设备行为；

```c
static int kvm_cmd_run_work(struct kvm *kvm)
{
	int i;

	for (i = 0; i < kvm->nrcpus; i++) {
		if (pthread_create(&kvm->cpus[i]->thread, NULL, kvm_cpu_thread, kvm->cpus[i]) != 0)
			die("unable to create KVM VCPU thread");
	}

	/* Only VCPU #0 is going to exit by itself when shutting down */
	if (pthread_join(kvm->cpus[0]->thread, NULL) != 0)
		die("unable to join with vcpu 0");

	return kvm_cpu__exit(kvm);
}

int kvm_cpu__start(struct kvm_cpu *cpu)
{
	//...
	kvm_cpu__reset_vcpu(cpu);

	while (cpu->is_running) {
		kvm_cpu__run(cpu);

        /* kvmtool处理Guest退出 */
		switch (cpu->kvm_run->exit_reason) {
                //...
        }
    }
}

int kvm_cpu__exit(struct kvm *kvm)
{
	int i, r;
	void *ret = NULL;

	kvm_cpu__delete(kvm->cpus[0]);
	kvm->cpus[0] = NULL;

	kvm__pause(kvm); 
	for (i = 1; i < kvm->nrcpus; i++) {
		if (kvm->cpus[i]->is_running) {
			pthread_kill(kvm->cpus[i]->thread, SIGKVMEXIT);
			if (pthread_join(kvm->cpus[i]->thread, &ret) != 0)
				die("pthread_join");
			kvm_cpu__delete(kvm->cpus[i]);
		}
		if (ret == NULL)
			r = 0;
	}
	kvm__continue(kvm);

	free(kvm->cpus);

	kvm->nrcpus = 0;

	close(task_eventfd);

	return r;
}
```

对接KVM的用户态程序，无论kvmtool还是qemu，从KVM内核态退出有两种情况：

* Guest异常，最常见的就是MMIO访问错误，kvmtool模拟设备行为后将再次返回KVM。对应的就是在 `kvm_cpu__start` 的vcpu-run循环内处理Guest异常，不会脱离循环；这个后面重点分析。
* 虚拟机彻底销毁，对应的是 `kvm_cpu__exit`，其逻辑是清空以及释放各对象内存。第一个执行到此的vcpu线程将在 `kvm__pause` 中持有 `pause_lock`，后续该vcpu线程将负责虚拟机的清理工作，释放锁后其余vcpu线程直接退出；

---

下面看 kvmtool 如何处理各种VM_EXIT事件的。整体流程就是处理各种 `case KVM_EXIT_*`，先看default处理 `kvm_cpu__handle_exit` 和最后的公共处理函数 `kvm_cpu__handle_coalesced_mmio`：

```c
switch (cpu->kvm_run->exit_reason) {
		//...
		default: {
			bool ret;

			ret = kvm_cpu__handle_exit(cpu);
			if (!ret)
				goto panic_kvm;
			break;
		}
		}
		kvm_cpu__handle_coalesced_mmio(cpu);
	}

------------------------------------------------------
bool kvm_cpu__handle_exit(struct kvm_cpu *vcpu)
{
	switch (vcpu->kvm_run->exit_reason) {
	case KVM_EXIT_RISCV_SBI:
		return kvm_cpu_riscv_sbi(vcpu);
	default:
		break;
	};

	return false;
}

static void kvm_cpu__handle_coalesced_mmio(struct kvm_cpu *cpu)
{
	if (cpu->ring) {
		while (cpu->ring->first != cpu->ring->last) {
			struct kvm_coalesced_mmio *m;
			m = &cpu->ring->coalesced_mmio[cpu->ring->first];
			kvm_cpu__emulate_mmio(cpu,
					      m->phys_addr,
					      m->data,
					      m->len,
					      1);
			cpu->ring->first = (cpu->ring->first + 1) % KVM_COALESCED_MMIO_MAX;
		}
	}
}
```

* `kvm_cpu__handle_exit`

  kvmtool处理 `KVM_EXIT_RISCV_SBI`，调用 `kvm_cpu_riscv_sbi` 函数：

  ```c
  static bool kvm_cpu_riscv_sbi(struct kvm_cpu *vcpu)
  {
  	char ch;
  	bool ret = true;
  	int dfd = kvm_cpu__get_debug_fd();
  
  	switch (vcpu->kvm_run->riscv_sbi.extension_id) {
  	case SBI_EXT_0_1_CONSOLE_PUTCHAR:
  		ch = vcpu->kvm_run->riscv_sbi.args[0];
  		term_putc(&ch, 1, 0);
  		vcpu->kvm_run->riscv_sbi.ret[0] = 0;
  		break;
  	case SBI_EXT_0_1_CONSOLE_GETCHAR:
  		if (term_readable(0))
  			vcpu->kvm_run->riscv_sbi.ret[0] =
  					term_getc(vcpu->kvm, 0);
  		else
  			vcpu->kvm_run->riscv_sbi.ret[0] = SBI_ERR_FAILURE;
  		break;
  	default:
  		dprintf(dfd, "Unhandled SBI call\n");
  		dprintf(dfd, "extension_id=0x%lx function_id=0x%lx\n",
  			vcpu->kvm_run->riscv_sbi.extension_id,
  			vcpu->kvm_run->riscv_sbi.function_id);
  		dprintf(dfd, "args[0]=0x%lx args[1]=0x%lx\n",
  			vcpu->kvm_run->riscv_sbi.args[0],
  			vcpu->kvm_run->riscv_sbi.args[1]);
  		dprintf(dfd, "args[2]=0x%lx args[3]=0x%lx\n",
  			vcpu->kvm_run->riscv_sbi.args[2],
  			vcpu->kvm_run->riscv_sbi.args[3]);
  		dprintf(dfd, "args[4]=0x%lx args[5]=0x%lx\n",
  			vcpu->kvm_run->riscv_sbi.args[4],
  			vcpu->kvm_run->riscv_sbi.args[5]);
  		ret = false;
  		break;
  	};
  
  	return ret;
  }
  ```

  处理来自于Guest的两种SBI：`SBI_EXT_0_1_CONSOLE_PUTCHAR`、`SBI_EXT_0_1_CONSOLE_GETCHAR`。为什么不直接在KVM中处理呢？

  > 这里给出了解释：[Re: PATCH v5 18/20\] RISC-V: KVM: Add SBI v0.1 support — Linux KVM (spinics.net)](https://www.spinics.net/lists/kvm/msg194084.html)
  >
  > The SBI_CONSOLE_PUTCHAR and SBI_CONSOLE_GETCHAR are for debugging only. These calls are deprecated in SBI v0.2 onwards because we now have earlycon for early prints in Linux RISC-V. The RISC-V Guest will generally have it's own MMIO based UART which will be the default console. Due to these reasons, we have not implemented these SBI calls.
  >
  > That's up to user space (QEMU / kvmtool) to decide. If user space wants to implement the  console functions (like we do on s390), it should have the chance to do so.

* `kvm_cpu__handle_coalesced_mmio`

  遍历 `cpu->ring` 中的所有kvm_coalesced_mmio对象，调用 `kvm_cpu__emulate_mmio` 模拟IO。

---

### KVM_EXIT_DEBUG

```c
		case KVM_EXIT_DEBUG:
			kvm_cpu__show_registers(cpu);
			kvm_cpu__show_code(cpu);
			break;
-----------------------------------------------
void kvm_cpu__show_registers(struct kvm_cpu *vcpu)
{
	struct kvm_one_reg reg;
	unsigned long data;
	int debug_fd = kvm_cpu__get_debug_fd();
	struct kvm_riscv_core core;

	reg.addr = (unsigned long)&data;

	reg.id		= RISCV_CORE_REG(mode);
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (mode)");
	core.mode = data;

	reg.id		= RISCV_CORE_REG(regs.pc);
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (pc)");
	core.regs.pc = data;
    
    //...
    kvm_cpu__show_csrs(vcpu);
}

static void kvm_cpu__show_csrs(struct kvm_cpu *vcpu)
{
	struct kvm_one_reg reg;
	struct kvm_riscv_csr csr;
	unsigned long data;
	int debug_fd = kvm_cpu__get_debug_fd();

	reg.addr = (unsigned long)&data;
	dprintf(debug_fd, "\n Control Status Registers:\n");
	dprintf(debug_fd,   " ------------------------\n");

	reg.id		= RISCV_CSR_REG(sstatus);
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (sstatus)");
	csr.sstatus = data;
    //...
}

void kvm_cpu__show_code(struct kvm_cpu *vcpu)
{
	struct kvm_one_reg reg;
	unsigned long data;
	int debug_fd = kvm_cpu__get_debug_fd();

	reg.addr = (unsigned long)&data;

	dprintf(debug_fd, "\n*PC:\n");
	reg.id = RISCV_CORE_REG(regs.pc);
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (show_code @ PC)");

	kvm__dump_mem(vcpu->kvm, data, 32, debug_fd);

	dprintf(debug_fd, "\n*RA:\n");
	reg.id = RISCV_CORE_REG(regs.ra);
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (show_code @ RA)");

	kvm__dump_mem(vcpu->kvm, data, 32, debug_fd);
}
```

### KVM_EXIT_IO

//x86独占

### KVM_EXIT_MMIO

```c
		case KVM_EXIT_MMIO: {
			bool ret;

			/*
			 * If we had MMIO exit, coalesced ring should be processed
			 * *before* processing the exit itself
			 */
			kvm_cpu__handle_coalesced_mmio(cpu);

			ret = kvm_cpu__emulate_mmio(cpu,
						    cpu->kvm_run->mmio.phys_addr,
						    cpu->kvm_run->mmio.data,
						    cpu->kvm_run->mmio.len,
						    cpu->kvm_run->mmio.is_write);

			if (!ret)
				goto panic_kvm;
			break;
------------------------------------------------------------------------

```

* **先处理 Coalesced Ring 的原因**：
  - **性能优化**：通过首先处理 coalesced ring，可以优先处理已经合并的多个 I/O 操作，这可以大幅减少 VM Exit 的次数，从而提高整体的虚拟机性能。
  - **操作顺序的正确性**：在某些情况下，先处理合并的 I/O 操作可以确保操作的执行顺序与预期一致，特别是在涉及到连续地址空间的读写时。这有助于保持虚拟机内部状态的一致性和正确性。

---



### KVM_EXIT_INTR/KVM_EXIT_SHUTDOWN

### KVM_EXIT_SYSTEM_EVENT











## 2.5 kvmtool设备模拟

### 1) IO端口

现在有了CPU与内存之后，虽然能运行，但是还缺少与外部设备沟通的能力。**内存映射 I/O ( MMIO )** 和**端口映射 I/O ( PMIO )**，是CPU和外围设备之间，执行输入/输出 (I/O) 的两种互补方法。

- `MMIO`

  IO设备的内存和寄存器，被映射到内存地址空间中。此时CPU可以像访问内存一样，通过 `mov [addr], ...` 指令访问IO设备。这种设计，必须要为IO设备单独划分出一部分内存空间。

- `PMIO`

  这类方法，需要CPU设计一类特殊的指令，比如x86的 `in、out` 指令。IO设备，有一个与内存地址独立的地址空间，称之为IO端口空间，使用一个端口号来表示一个设备的内存或者寄存器。通过IO端口选定设备后，CPU就可用 `in/out` 指令对其进行读写。

整体结构如下图：

<img src="https://picx.zhimg.com/80/v2-b360a98153750e9683ad40cdf702a627_1440w.webp?source=d16d100b" alt="img" style="zoom: 67%;" />

CPU要访问的内存地址与IO地址，都会通过系统总线发送到北桥中，北桥会进行识别，如果是内存地址则发送到内存总线，如果是IO地址则会传递给负责外设的南桥处理。

16位处理器中，由于内存寻址空间有限，多使用PMIO的方式，但PMIO一次最多写入4字节，速度不及MMIO，因此到了32位和64位的时代，当寻址空间足够时就更多的使用MMIO。

#### a. IO端口初始化: ioport_setup_arch

该函数由 `init_list__init()` 调用，属于设备级别的初始化函数，会多次调用 `kvm__register_pio()` 用于为虚拟机注册IO端口。

```c
static int ioport__setup_arch(struct kvm* kvm)
{
    int r;

    /* 传统的io端口设置 */

    /* 0000 - 001F - DMA1控制器 */
    r = kvm__register_pio(kvm, 0x0000, 32, dummy_io, NULL);

    /* 0x0020 - 0x003F - 8285A中断控制器 1 */
    r = kvm__register_pio(kvm, 0x0020, 2, dummy_io, NULL);

    /* PORT 0040-005F - PIT: 可编程计时器(8253, 8254) */
    r = kvm__register_pio(kvm, 0x0040, 4, dummy_io, NULL);

    ...; //类似格式, 设置别的IO端口

    return 0;
}
dev_base_init(ioport__setup_arch);

//dummy_io为空函数
static void dummy_io(struct kvm_cpu* vcpu, u64 addr, u8* data, u32 len,
    u8 is_write, void* ptr)
{
}
```

`kvm__register_pio()` 函数，会调用 `kvm__register_iotrap()` 注册一个IO陷入，每当Guest访问这个PMIO或者MMIO时，都会引发虚拟机退出：

```c
//IO指令处理函数的类型
typedef void (*mmio_handler_fn)(struct kvm_cpu *vcpu, u64 addr, u8 *data, u32 len, u8 is_write, void *ptr)

//注册一个端口映射, 端口范围为[port, port+len), 当Guest对此范围的端口进行IO时会调用mmio_handler函数, ptr为额外参数
static inline int __must_check kvm__register_pio(struct kvm* kvm, u16 port, u16 len, mmio_handler_fn mmio_fn, void* ptr)
{
    return kvm__register_iotrap(kvm, port, len, mmio_fn, ptr, DEVICE_BUS_IOPORT);
}
```

实际上，不管是PMIO还是MMIO，kvmtool中都使用 `struct mmio_mapping` 结构，来表示要注册的IO地址区间和处理函数，对于MMIO会记录在 `mmio_tree` 中，对于PMIO会记录在 `pio_tree` 中。使用红黑树可以加快，根据地址搜索 `struct mmio_mapping` 的速度，具体数据结构如下所示：

```c
static struct rb_root mmio_tree = RB_ROOT;  //MMIO记录到这个红黑树
static struct rb_root pio_tree = RB_ROOT;   //PMIO记录到这个红黑树

struct mmio_mapping {
    struct rb_int_node node;    //红黑树节点
    mmio_handler_fn mmio_fn;    //处理函数
    void* ptr;  //额外参数
    u32 refcount;   //引用计数
    bool remove;
};

struct rb_int_node {
    struct rb_node  node;
    u64     low;
    u64     high;
};
```

`kvm__register_iotrap` 首先需要把IO陷入注册到KVM中，然后再注册到kvmtool内部的红黑树中。注意只有在MMIO时，才需要通知KVM对MMIO区间进行合并处理，PMIO总会引起虚拟机退出 (大部分端口是这样，IO端口是否会引起VM_EXIT可以通过VMCS设置)。

> 关于KVM_REGISTER_COALESCED_MMIO细节见： [qemu+kvm coalesced MMIO机制 - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/681103883)
>
> 用户态只需向KVM注册虚拟机RAM空间即可，MMIO区间无需调用ioctl KVM_SET_USER_MEMORY_REGION通知KVM，由于KVM未给相应的MMIO空间建立 `stage-2` 映射，Guest驱动尝试访问设备时，将触发虚拟机页错误，在KVM异常处理流程中将判断该地址是否为合法地址 `is_error_hva?`，如果不是，则为MMIO页访问异常，否则为其建立 `stage-2` 映射。   

```c
int kvm__register_iotrap(struct kvm* kvm, u64 phys_addr, u64 phys_addr_len, mmio_handler_fn mmio_fn, void* ptr, unsigned int flags)
{
    struct mmio_mapping* mmio;
    struct kvm_coalesced_mmio_zone zone;
    int ret;

    //申请一个mmio_mapping对象
    mmio = malloc(sizeof(*mmio));

    //初始化
    *mmio = (struct mmio_mapping) {
        .node = RB_INT_INIT(phys_addr, phys_addr + phys_addr_len),  // IO端口的范围 / IO地址的范围
        .mmio_fn = mmio_fn, //处理函数
        .ptr = ptr, //额外参数
        .refcount = 0,  //引用计数从0开始, 因为kvm_deregister_mmio()不会减少引用计数
        .remove = false,    //是否移除
    };

    //对于MMIO, 需要告诉KVM这片内存需要合并处理
    if (trap_is_mmio(flags) && (flags & IOTRAP_COALESCE)) {
        zone = (struct kvm_coalesced_mmio_zone) {
            .addr = phys_addr,
            .size = phys_addr_len,
        };
        ret = ioctl(kvm->vm_fd, KVM_REGISTER_COALESCED_MMIO, &zone);
    }

    //对于PMIO并不需要通知KVM, 因为Guest执行in out指令时一定会引起虚拟机退出

    //根据IO类型注册到对应的红黑树中, 方便虚拟机退出时kvmtool快速找到对应的处理函数
    mutex_lock(&mmio_lock);
    if (trap_is_mmio(flags))
        ret = mmio_insert(&mmio_tree, mmio);
    else
        ret = mmio_insert(&pio_tree, mmio);
    mutex_unlock(&mmio_lock);

    return ret;
}
```

接下来会用8250设备作为例子，看一些串口设备的模拟流程。

#### b. 串口输出设备

在计算机一开始，并没有图形显示器，所有要输出的消息先一个字符一个字符的，输出到**通用异步收发传输器(UART)**，再由UART输出到电传机 (TTY) 等终端设备。8250就是一种UART设备，内核中自带有UART设备的驱动，如下图：

![img](https://picx.zhimg.com/80/v2-77d7aa65a7453ffe09ba58200190dafb_1440w.webp?source=d16d100b)

后续随着计算机的发展，TTY设备已经被淘汰。但是linux保留了这个名词，使用tty泛指用于输出的终端设备。控制台与终端的概念类似，可以认为是用于输出内核消息的特殊终端。我们在内核启动参数中可以看到，kvmtool默认把串口终端(ttyS0)作为控制台(console)，而没有使用VGA这样的视频设备。

![img](https://pic1.zhimg.com/80/v2-fb7728d90ce60fc3e5a1ae21673a7303_1440w.webp?source=d16d100b)

综上，内核要输出的信息，都是通过读写UART设备完成的，kvmtool通过虚拟化UART设备8250，从而把要输出的信息，全部打印到Host的STDOUT中，也就是我们在主机终端中看到的信息。下面我们来研究下其实现过程。

#### c. 初始化: serial8250_init

接下来，具体8250设备怎么模拟，则涉及到该设备的物理特性。这份手册详细描述了PC应该如何使用[8250设备](http://link.zhihu.com/?target=https%3A//www.techedge.com.au/tech/8250tec.htm), kvmtool的模拟工作基本都是参考这份手册开展的。

> **8250设备对应的IO端口地址，如下：**

```c
There are four main address that are used by the PC's UART.
Port     Address    Interrupt
-----------------------------
COM1       3F8        IRQ4
COM2       2F8        IRQ3
COM3       3E8        IRQ4*
COM4       2E8        IRQ3*
```

> **8250设备寄存器定义，如下：**

```c
offset  name    Function        Use
--------------------------------------------------------------------------
  0*    DATA 数据读写寄存器.       行IO
  1*    IER 中断启动寄存器.        启动Tx Rx RxError Modem中断
  2 	IID 中断ID寄存器.         最高中断源的ID
  3 	LCR 行控制寄存器.         行控制参数 Line control parameters and Break.
  4 	MCR 模式控制寄存器.       DTR, RTS, OUT1, OUT2 and loopback.
  5 	LSR 行状态寄存器.         Tx和Rx的状态(PE FE OE)
  6 	MSR 模式状态寄存器.        CTS, DSR, RI, RLSD & changes.

  0*    DLL Divisor Latch LOW   波特率除数的低位
  1*    DLH Divisor Latch HIGH  波特率除数的高位
```

---

kvmtool使用 `struct serial8250_device` 结构，表示一个8250设备：

```c
struct serial8250_device {
    struct device_header dev_hdr;   //设备头
    struct mutex mutex; //互斥锁
    u8 id;

    u32 iobase; //IO端口基址
    u8 irq;
    u8 irq_state;
    int txcnt;
    int rxcnt;
    int rxdone;
    char txbuf[FIFO_LEN];
    char rxbuf[FIFO_LEN];

    u8 dll;
    u8 dlm;
    u8 iir;
    u8 ier;
    u8 fcr;
    u8 lcr;
    u8 mcr;
    u8 lsr;
    u8 msr;
    u8 scr;
};
```

设备头 `struct device_header` 定义如下，这是kvmtool中所有设备所共有的对象，kvmtool会用 `dev_num` 作为key建立一个红黑树，用于快速找到设备：

```c
enum device_bus_type {
    DEVICE_BUS_PCI,
    DEVICE_BUS_MMIO,
    DEVICE_BUS_IOPORT,
    DEVICE_BUS_MAX,
};

struct device_header {
    enum device_bus_type bus_type; //总线类型
    void* data; //数据
    int dev_num; //设备号
    struct rb_node node; //红黑树节点
};
```

---

kvmtool为Guest设置了4个8250设备，分别对应 `ttyS0 ttyS1 ttyS2 ttyS3` 四个终端。设备对象全部保存在局部数组 `devices` 中, 具体定义如下：

```c
#define serial_iobase_0 (KVM_IOPORT_AREA + 0x3f8)
#define serial_iobase_1 (KVM_IOPORT_AREA + 0x2f8)
#define serial_iobase_2 (KVM_IOPORT_AREA + 0x3e8)
#define serial_iobase_3 (KVM_IOPORT_AREA + 0x2e8)
#define serial_irq_0 4
#define serial_irq_1 3
#define serial_irq_2 4
#define serial_irq_3 3
#define serial_iobase(nr) serial_iobase_##nr
#define serial_irq(nr) serial_irq_##nr
#define SERIAL8250_BUS_TYPE DEVICE_BUS_IOPORT

static struct serial8250_device devices[] = {
    /* ttyS0 */
    [0] = {
        .dev_hdr = {
            .bus_type = SERIAL8250_BUS_TYPE,    //总线类型
            .data = serial8250_generate_fdt_node,
        },
        .mutex = MUTEX_INITIALIZER,

        .id = 0,
        .iobase = serial_iobase(0),
        .irq = serial_irq(0),

        SERIAL_REGS_SETTING },
    /* ttyS1 */
    [1] = { .dev_hdr = {
                .bus_type = SERIAL8250_BUS_TYPE,
                .data = serial8250_generate_fdt_node,
            },
        .mutex = MUTEX_INITIALIZER,

        .id = 1,
        .iobase = serial_iobase(1),
        .irq = serial_irq(1),

        SERIAL_REGS_SETTING },
    /* ttyS2 */
    [2] = { .dev_hdr = {
                .bus_type = SERIAL8250_BUS_TYPE,
                .data = serial8250_generate_fdt_node,
            },
        .mutex = MUTEX_INITIALIZER,

        .id = 2,
        .iobase = serial_iobase(2),
        .irq = serial_irq(2),

        SERIAL_REGS_SETTING },
    /* ttyS3 */
    [3] = { .dev_hdr = {
                .bus_type = SERIAL8250_BUS_TYPE,
                .data = serial8250_generate_fdt_node,
            },
        .mutex = MUTEX_INITIALIZER,

        .id = 3,
        .iobase = serial_iobase(3),
        .irq = serial_irq(3),

        SERIAL_REGS_SETTING },
};
```

`serial8250__init()` 会遍历8250设备数组 `devices`，对其中的每一个设备调用`serial8250__device_init()` 进行初始化：

```c
int serial8250__init(struct kvm* kvm)
{
    unsigned int i, j;
    int r = 0;

    //初始化每一个8250设备
    for (i = 0; i < ARRAY_SIZE(devices); i++) {
        struct serial8250_device* dev = &devices[i];
        r = serial8250__device_init(kvm, dev);
    }

    return r;
    //...;    //异常处理  
}
dev_init(serial8250__init);
```

`serial8250__device_init` 首先需要注册设备，然后通过IO映射，把设备的IO端口添加到Guest中：

```c
static int serial8250__device_init(struct kvm* kvm, struct serial8250_device* dev)
{
    int r;

    //注册设备到kvmtool设备树中
    r = device__register(&dev->dev_hdr);
    if (r < 0)
        return r;

    //把该设备映射到Guest的IO空间中
    r = kvm__register_iotrap(kvm, dev->iobase, 8, 
                             serial8250_mmio, dev, SERIAL8250_BUS_TYPE);

    return r;
}
```

物理机中所有的外设，通过各种总线连接到CPU，因此kvmtool使用 `struct device_bus` 来表示一类总线，该总线通过红黑树组织所有连接的设备。

```c
enum device_bus_type {
    DEVICE_BUS_PCI,
    DEVICE_BUS_MMIO,
    DEVICE_BUS_IOPORT,
    DEVICE_BUS_MAX,    //总线类型
};

//表示设备总线, 内部通过红黑树组织设备
struct device_bus {
    struct rb_root root;    //红黑树的根
    int dev_num;    //下一个设备号
};

//所有总线的数组
static struct device_bus device_trees[DEVICE_BUS_MAX] = {
    [0 ...(DEVICE_BUS_MAX - 1)] = { RB_ROOT, 0 },
};
```

---

设备注册函数 `device__register`，先为设备分配设备号，然后根据设备号添加总线中，这样kvmtool就可以感知该设备的存在。

```c
int device__register(struct device_header* dev)
{
    struct device_bus* bus;
    struct rb_node **node, *parent = NULL;

    //不同设备根据总线类型组织为设备树
    bus = &device_trees[dev->bus_type];

    //获取设备号
    dev->dev_num = bus->dev_num++;

    //以设备号为key插入到总线的红黑树中
    node = &bus->root.rb_node;
    while (*node) {
        int num = rb_entry(*node, struct device_header, node)->dev_num;
        int result = dev->dev_num - num;

        parent = *node;
        if (result < 0)
            node = &((*node)->rb_left);
        else if (result > 0)
            node = &((*node)->rb_right);
        else
            return -EEXIST;
    }

    rb_link_node(&dev->node, parent, node);
    rb_insert_color(&dev->node, &bus->root);
    return 0;
}
```

之后会调用 `kvm__register_iotrap`，设置IO端口，这样每当Guest对 `dev->iobase` 端口，执行 `in/out` 指令或MMIO访存时，就会引发虚拟机退出，kvmtool就会调用对应的处理函数，接下来我们就会研究该过程的实现。

#### d. KVM_EXIT_IO的处理

当Guest执行了KVM无法满足的端口IO指令，或触发MMIO访问异常时，会引发虚拟机退出。KVM会在CPU共享内存中，写入 `struct io/mmio` 结构的数据，用于告诉kvmtool Guest执行了什么io指令，结构如下：

```c
struct kvm_run {
    //...
    
    union {
        /* KVM_EXIT_IO */
		struct {
#define KVM_EXIT_IO_IN  0
#define KVM_EXIT_IO_OUT 1
			__u8 direction;
			__u8 size; /* bytes */
			__u16 port;
			__u32 count;
			__u64 data_offset; /* relative to kvm_run start */
		} io;
        /* KVM_EXIT_MMIO */
		struct {
			__u64 phys_addr;
			__u8  data[8];
			__u32 len;
			__u8  is_write;
		} mmio;
    }
    
    //...
}
```

Guest退出到KVM之后，将会从 `ioctl(..., KVM_RUN, 0)` 退出，退出原因为`KVM_EXIT_IO`。

```c
int kvm_cpu__start(struct kvm_cpu* cpu)
{
    sigset_t sigset;

    ...;    //信号处理相关

    //重置CPU状态
    kvm_cpu__reset_vcpu(cpu);

    //CPU循环
    while (cpu->is_running) {

        //通知KVM开始cpu的执行
        kvm_cpu__run(cpu);

        //处理CPU退出原因
        switch (cpu->kvm_run->exit_reason) {
        case KVM_EXIT_IO: { //因为IO端口引发的vmexit
            bool ret;

            //对io端口进行模拟, cpu->kvm_run为先前为CPU申请的共享内存
            //kvmtool会通过这个来获取VMEXIT的相关信息
            ret = kvm_cpu__emulate_io(cpu,
                cpu->kvm_run->io.port,  //IO端口
                (u8*)cpu->kvm_run + cpu->kvm_run->io.data_offset,   //数据在kvm_run中的偏移
                cpu->kvm_run->io.direction, //IO指令的方向: in / out
                cpu->kvm_run->io.size,  //IO操作的大小
                cpu->kvm_run->io.count);    //多少次IO操作

            if (!ret)
                goto panic_kvm;
            break;
        case KVM_EXIT_MMIO: {
            bool ret;
            /*
             * If we had MMIO exit, coalesced ring should be processed
             * *before* processing the exit itself
             */
            kvm_cpu__handle_coalesced_mmio(cpu);

            ret = kvm_cpu__emulate_mmio(cpu,
                            cpu->kvm_run->mmio.phys_addr,
                            cpu->kvm_run->mmio.data,
                            cpu->kvm_run->mmio.len,
                            cpu->kvm_run->mmio.is_write);

            if (!ret)
                goto panic_kvm;
            break;
        }
    }

exit_kvm:
    return 0;
}
```

`kvm_cpu__emulate_io/mmio` 是 `kvm__emulate_io/mmio` 的包裹函数：

```c
/*
 * As these are such simple wrappers, let's have them in the header so they'll
 * be cheaper to call:
 */
static inline bool kvm_cpu__emulate_io(struct kvm_cpu *vcpu, u16 port, void *data, int direction, int size, u32 count)
{
	return kvm__emulate_io(vcpu, port, data, direction, size, count);
}

static inline bool kvm_cpu__emulate_mmio(struct kvm_cpu *vcpu, u64 phys_addr, u8 *data, u32 len, u8 is_write)
{
	return kvm__emulate_mmio(vcpu, phys_addr, data, len, is_write);
}
```

`kvm__emulate_io()` 会根据port找到对应的IO映射对象, 然后调用其处理函数。`kvm__emulate_mmio` 流程与之类似：

```c
bool kvm__emulate_io(struct kvm_cpu* vcpu, u16 port, void* data, int direction, int size, u32 count)
{
    struct mmio_mapping* mmio;
    bool is_write = direction == KVM_EXIT_IO_OUT;

    //根据端口号port和读写大小size, 从pio红黑树中找到对应的IO映射
    mmio = mmio_get(&pio_tree, port, size);
    ...;    //没找到时的异常处理

    //执行count次IO处理函数
    while (count--) {
        mmio->mmio_fn(vcpu, port, data, size, is_write, mmio->ptr);

        data += size;
    }

    // 如果该IO设备可以移除, 那么IO映射的寿命-1, 寿命耗尽时会被移除
    mmio_put(vcpu->kvm, &pio_tree, mmio);

    return true;
}

bool kvm__emulate_mmio(struct kvm_cpu *vcpu, u64 phys_addr, u8 *data,
		       u32 len, u8 is_write)
{
	struct mmio_mapping *mmio;

	mmio = mmio_get(&mmio_tree, phys_addr, len);
	if (!mmio) {
		if (vcpu->kvm->cfg.mmio_debug)
			fprintf(stderr,	"MMIO warning: Ignoring MMIO %s at %016llx (length %u)\n",
				to_direction(is_write),
				(unsigned long long)phys_addr, len);
		goto out;
	}

	mmio->mmio_fn(vcpu, phys_addr, data, len, is_write, mmio->ptr);
	mmio_put(vcpu->kvm, &mmio_tree, mmio);

out:
	return true;
}
```

在8250设备初始化流程中，已经注册好了对应的设备行为模拟函数，接下来将调用 `serial8250_mmio()` 。

#### e. 8250设备的模拟

`serial8250_mmio()` 首先会根据IO的方向选择对应处理函数，调用时会计算端口的偏移，也就是 `addr - dev->iobase`，因此一个设备会映射多个端口，不同端口具有不同的功能。

```c
static void serial8250_mmio(struct kvm_cpu* vcpu, u64 addr, u8* data, u32 len, u8 is_write, void* ptr)
{
    struct serial8250_device* dev = ptr;

    if (is_write) 
        serial8250_out(dev, vcpu, addr - dev->iobase, data);
    else
        serial8250_in(dev, vcpu, addr - dev->iobase, data);
}
```

以 `serial8250_out()` 为例，会把要输出的字符压入8250设备的输出缓冲区 `txbuf` 中，然后调用`serial8250_flush_tx()` 刷新缓冲区。

```c
//offset = 本次Guest访问的IO端口 - 设备的起始IO端口
static bool serial8250_out(struct serial8250_device* dev, struct kvm_cpu* vcpu, u16 offset, void* data)
{
    bool ret = true;
    char* addr = data;

    mutex_lock(&dev->mutex); //独占访问本设备

    switch (offset) {
    case UART_TX:   //操作的是数据传输寄存器
        if (dev->lcr & UART_LCR_DLAB) { //如果lcr设置了初始访问标志Divisor Latch Access Bit.
            dev->dll = ioport__read8(data); //那么这个数据传输要写入dll, 保存波特率除数的低位
            break;
        }

        /* Loopback mode */
        if (dev->mcr & UART_MCR_LOOP) { //如果mcr设置了Loopback标志
            if (dev->rxcnt < FIFO_LEN) {    //则向rxbuf中压入一个字符
                dev->rxbuf[dev->rxcnt++] = *addr;
                dev->lsr |= UART_LSR_DR;
            }
            break;
        }

        //对于大多数情况
        if (dev->txcnt < FIFO_LEN) {    //如果缓冲区还有位置
            dev->txbuf[dev->txcnt++] = *addr;   //则向输出缓冲区压入一个字符
            dev->lsr &= ~UART_LSR_TEMT;     //清除行状态寄存器lsr的 Transmitter empty标志
            if (dev->txcnt == FIFO_LEN / 2) //如果缓冲区使用了一半
                dev->lsr &= ~UART_LSR_THRE; //则清除lsr的Transmit-hold-register empty标志
            serial8250_flush_tx(vcpu->kvm, dev);        //刷新发送缓冲区
        } else {
            /* Should never happpen */
            dev->lsr &= ~(UART_LSR_TEMT | UART_LSR_THRE);
        }
        break;
        //...;
    }

    serial8250_update_irq(vcpu->kvm, dev);
    mutex_unlock(&dev->mutex);
    return ret;
}
```

`serial8250_flush_tx` 会刷新内部保存的字符，再调用 `term_putc` 输出到Host的终端中。

```c
//刷新tx数据缓冲区
static void serial8250_flush_tx(struct kvm* kvm, struct serial8250_device* dev)
{
    dev->lsr |= UART_LSR_TEMT | UART_LSR_THRE;

    if (dev->txcnt) {   //如果有数据, 就在终端中输出一个字符
        term_putc(dev->txbuf, dev->txcnt, dev->id);
        dev->txcnt = 0;
    }
}
```

后续，kvmtool将调用 `serial8250_update_irq`，注入虚拟中断：

```c
static void serial8250_update_irq(struct kvm *kvm, struct serial8250_device *dev)
{
	u8 iir = 0;
    
    //...

	/* Now update the irq line, if necessary */
	if (!iir) {
		dev->iir = UART_IIR_NO_INT;
		if (dev->irq_state)
			kvm__irq_line(kvm, dev->irq, 0);
	} else {
		dev->iir = iir;
		if (!dev->irq_state)
			kvm__irq_line(kvm, dev->irq, 1);
	}
	dev->irq_state = iir;

	/*
	 * If the kernel disabled the tx interrupt, we know that there
	 * is nothing more to transmit, so we can reset our tx logic
	 * here.
	 */
	if (!(dev->ier & UART_IER_THRI))
		serial8250_flush_tx(kvm, dev);
}

void kvm__irq_line(struct kvm *kvm, int irq, int level)
{
	struct kvm_irq_level irq_level;

	if (riscv_irqchip_inkernel) {
		irq_level.irq = irq;
		irq_level.level = !!level;
		if (ioctl(kvm->vm_fd, KVM_IRQ_LINE, &irq_level) < 0)
			pr_warning("%s: Could not KVM_IRQ_LINE for irq %d\n",
				   __func__, irq);
	} else {
		if (riscv_irqchip_trigger)
			riscv_irqchip_trigger(kvm, irq, level, false);
		else
			pr_warning("%s: Can't change level for irq %d\n",
				   __func__, irq);
	}
}
```

从上面可以看到，进一步调用 `kvm__irq_line`，分两种情况：

* `riscv_irqchip_inkernel == true`: 内核态模拟中断控制器，比如riscv_aia；

* `riscv_irqchip_inkernel == false`: 用户态模拟中断控制器，比如riscv_plic：

  ```c
  void plic__create(struct kvm *kvm)
  {
  	if (riscv_irqchip != IRQCHIP_UNKNOWN)
  		return;
  
  	riscv_irqchip = IRQCHIP_PLIC;
  	riscv_irqchip_inkernel = false;
  	riscv_irqchip_trigger = plic__irq_trig;
      //...
  }
  
  static void plic__irq_trig(struct kvm *kvm, int irq, int level, bool edge)
  {
  	bool irq_marked = false;
  	u8 i, irq_prio, irq_word;
  	u32 irq_mask;
  	struct plic_context *c = NULL;
  	struct plic_state *s = &plic;
  	
      //...
  	for (i = 0; i < s->num_context; i++) {
  		c = &s->contexts[i];
  
  		mutex_lock(&c->irq_lock);
  		if (c->irq_enable[irq_word] & irq_mask) {
  			if (level) {
  				c->irq_pending[irq_word] |= irq_mask;
  				c->irq_pending_priority[irq] = irq_prio;
  				if (edge)
  					c->irq_autoclear[irq_word] |= irq_mask;
  			} else {
  				c->irq_pending[irq_word] &= ~irq_mask;
  				c->irq_pending_priority[irq] = 0;
  				c->irq_claimed[irq_word] &= ~irq_mask;
  				c->irq_autoclear[irq_word] &= ~irq_mask;
  			}
  			__plic_context_irq_update(s, c);  //注入虚拟中断
  			irq_marked = true;
  		}
  		mutex_unlock(&c->irq_lock);
  
  		if (irq_marked)
  			break;
  	}
  
  done:
  	mutex_unlock(&s->irq_lock);
  }
  
  /* Note: Must be called with c->irq_lock held */
  static void __plic_context_irq_update(struct plic_state *s,
  				      struct plic_context *c)
  {
  	u32 best_irq = __plic_context_best_pending_irq(s, c);
  	u32 virq = (best_irq) ? KVM_INTERRUPT_SET : KVM_INTERRUPT_UNSET;
  
  	if (ioctl(c->vcpu->vcpu_fd, KVM_INTERRUPT, &virq) < 0)
  		pr_warning("KVM_INTERRUPT failed");
  }
  ```

`ioctl(c->vcpu->vcpu_fd, KVM_INTERRUPT, &virq)` 将写相关的虚拟中断接口，注入一个虚拟中断，对于riscv来说就是 `hvip` 寄存器的虚拟机外部中断位VSEIP，返回Guest时硬件将触发一次VS态中断，随后进入Guest OS的中断向量入口进行处理。

---

之前，我们说过8250串口用于连接CPU和终端设备，那么下一步就是把字符发送到终端显示出来，下面研究kvmtool是如何实现终端设备的。

#### f. 终端设备term

##### 初始化: term_init







##### 向Guest发送字符: kvm__arch_read_term



##### 向Host输出数据: term_putc













### 2) PCI设备虚拟化



### 3) Virtio设备基础



### 4) Virtio Console实现



































