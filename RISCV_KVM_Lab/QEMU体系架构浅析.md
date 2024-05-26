# 0 问题







# 1 QEMU总体构成

从一个**软件功能**的角度来看，**qemu主要分为两大部分：**

* 硬件设备模拟(CPU、内存、外设等)；
* 对虚拟机的运维和管理，包括monitor和QME，主要是接收管理命令并处理，包括查询状态、动态添加删除设备、虚拟机迁移等。

可以说，qemu的源码都是为了这两个功能而服务的。

---

从**qemu源码组成**的角度来看，qemu的源码分为以下几个部分 (从大的体系架构上来讲，不包括具体的小的功能点，比如热迁移等)。

* **qemu选项子系统**

  这里为什么说是qemu选项子系统，而不简单的说qemu选项解析，是因为qemu支持的选项非常多，qemu对选项的支持和处理的代码相对较为复杂，足以称得上是一个子系统。qemu的选项子系统是阅读qemu源码要越过的第一道门槛，阅读qemu源码一定会是从qemu的选项子系统开始，因为qemu后续的初始化和运行都是根据qemu传入的选项来进行的，它是qemu之始。

* **QEMU对象模型 — QOM**

  它是QOM设备模拟的基础。QOM实现了一种面向对象的模型，所有的设备，包括CPU、内存、PCIe、外设都是基于QOM来实现的，由此可见，QEMU的代码不是按照传统C程序的顺序过程来编写的，而是融合了面向对象的思想，这进一步加大了QEMU代码的阅读难度。

* **monitor/QMP**

  这个是用来进行虚拟机运维管理的，它是为各种命令的接收和处理提供一个基本的通信机制，qemu的各个管理命令基于它实现自己的管理操作。QEMU的运维管理也是在QEMU硬件模拟的基础上进行的，所以对于开发者来说，要首先理解QEMU的设备模拟的原理和实现，刚开始可以不用关注该部分。

* **主事件循环**

  * 对于一般的大型软件来说，在基本的初始化完成后，都会进入一个主循环中，进行不断的处理过程。主事件循环是指循环是由事件驱动的，主循环不断的监控注册的各个事件，并调用相应的处理程序来处理该事件。
  * QEMU的主事件循环是基于glib库提供的 `gmainloop` 框架的基础上改造而来的，QEMU中monitor和VNC显示都是基于主事件循环来工作的。但是，QEMU并不是完全基于主事件循环来工作的，它是把主事件循环与多线程结合起来。qemu除了主线程的主事件循环外，还存在着许多其他的线程，比如每个vcpu都有一个线程来执行CPU模拟，此外根据需要还可以存在许多其他的IO线程，来执行具体IO设备的模拟工作。

---

当你把上述的几部分代码都看懂以后，对QEMU怎么模拟一个设备还是一头雾水，不得其门而入。这时因为QOM只是设备模拟的基础，不是设备模拟的过程，你要看基于QOM是怎么定义一个个设备对象的，以及这些设备对象是怎么组织成一个虚拟机的，因为虚拟机是一个有机的整体。虚拟机是在QEMU主函数中在执行QEMU初始化时一步步建立起来的。

# 2 QMEU选项子系统

QEMU的设备模拟是从QEMU的选项解析开始的，QEMU的选项定义了QEMU要模拟的虚拟机的形态，比如：虚拟机支持的CPU类型、有多少内存、虚拟机上有哪些外设等。QEMU支持的选项多达上百个，因此采用硬编码的方法来处理并不合适，需要把他们有效的组织和管理起来。

选项解析的第一步，是查询从命令行中传入的选项是否是qemu支持的选项，这需要从qemu支持的所有的选项集合中去匹配该选项，并给出该选项的id或索引，以在switch语句中去定位选项的处理流程。在qemu中所有的选项保存在 `QEMUOption qemu_options[]` 数组中。保存每个具体选项的结构体为QEMUOption：

```c
typedef struct QEMUOption {
    const char *name;
    int flags;
    int index;
    uint32_t arch_mask;
} QEMUOption;
```

每个选项都包括名字、flag、索引和支持的体系结构的掩码。所有的qemu选项都保存的在数组中，选项处理时根据命令行的选项名称从 `qemu_options[]` 数组中匹配到该选项，并给出index索引。所有的选项都转换为索引的好处时可以利用该索引在switch语句中统一处理。

* `lookup_opt` 函数，从参数中解析出一个选项及选项参数，然后参数的指针 `+2` 指向下一个选项，从全局选项数组中取出该选项的QEMUOption，返回该选项的参数的指针，接下来根据QEMUOption及参数指针，解析具体参数；
* 识别了选项之后，后面就是要解析选项了。QEMU是大型软件，它运行过程中的很多行为都是跟选项相关的，因此很多选项并不是解析的时候马上都会用到，所以需要保存起来，在需要用到的时候再来查询该选项；

QEMU的选项有非常多，其中很多选项都有很多子选项，因此有很多选项是相关的，作用于同一类设备或同一个子系统的。QEMU在保存解析出的选项的时候。是分类来保存的。QEMU与解析后的选项保存，相关的数据结构有4个不同的结构体：

```c
struct QemuOptsList {
    const char *name;
    const char *implied_opt_name;
    bool merge_lists;  /* Merge multiple uses of option into a single list? */
    QTAILQ_HEAD(, QemuOpts) head;
    QemuOptDesc desc[];
};
struct QemuOpts {
    char *id;
    QemuOptsList *list;
    Location loc;
    QTAILQ_HEAD(QemuOptHead, QemuOpt) head;
    QTAILQ_ENTRY(QemuOpts) next;
};
struct QemuOpt {
    char *name;
    char *str;

    const QemuOptDesc *desc;
    union {
        bool boolean;
        uint64_t uint;
    } value;

    QemuOpts     *opts;
    QTAILQ_ENTRY(QemuOpt) next;
};
typedef struct QemuOptDesc {
    const char *name;
    enum QemuOptType type;
    const char *help;
    const char *def_value_str;
} QemuOptDesc
```

* `QemuOptsList`

  * QemuOptList结构体用来保存某一类的选项，QEMU把选项分成了很多类，比如 `-drive` 选项，很多存储相关的选项及子选项保存在 `-drive` 大选项中；再比如 `-device` 选项，有很多不同种类的子选项，它也是一类选项。

  * QEMU中维护了一个QemuOptsList的数组，该数组中的每个成员都代表了解析出的一类选项，即QEMU是按照QemuOptsList来分类的。注意，并不是所有的选项都按分类的方式保存在QemuOptsList中了，有些简单的只有一个选择的选项，就没必要分类的保存在数组中了，直接保存在一个变量中就行了，比如 `-pidfile` 选项，指定存储qemu进程pid号的文件，直接把文件名参数保存在 `pid_file` 变量中就行了。

* `QemuOpts`

  * QemuOptsList中保存的大选项中有很多子选项，这些子选项保存在QemuOpts结构体中，一个QemuOpts保存了一个大选项相关的所有子选项，每个子选项都对应一个QemuOpt结构，因此QemuOpts里面实际保存是QemuOpt结构的链表。
  * 从QemuOptsList结构体的定义可以看出，QemuOptsList中保存的也是QemuOpts结构体的链表，就是说一个大选项可能有多个QemuOpts，但是QemuOpts已经保存了所有的子选项了，为什么会有多个QemuOpts结构体？这是因为，有些QEMU选项在命令行中不会使用一次，有可能一个选项使用多次，即一个大选项可能有多个同时存在的实例。比如，`-device` 选项是用来创建虚拟机外设的，你可以用来创建一个字符设备，也可以用来创建一个网络设备等，所以qemu命令行可以也可能，同时使用多次 `-device` 选项以创建多个不同的设备，每个设备都指定有各自的子选项。多个QemuOpts是用来保存同一类选项的不同实例的。

* `QemuOpt`

  QemuOpt结构保存的是一个个具体的子选项，以 `key/value` 对的方式保存，`key` 是子选项的名称，`value` 是命令行参数指定的子选项的值。

* `QemuOptDesc`

   QemuOptDesc保存的是选项的帮助信息或描述信息。

---

`qemu_opts_parse_noisily` 函数，用于解析某一个大选项，他先创建一个QemuOpts，然后从参数中解析出每个子选项 `key/value` 对，并为每个 `key/value` 对创建Qemuopt。`qemu_opt_set/opt_set` 函数用于在Qemuopts中新添加一个Qemuopt结构的 `key/value` 对。

QEMU的选项解析，将调用解析函数去解析每个命令行参数，并把解析出的选项保存在QemuOptsList数组中，一些不需要保存在数组中的选项，那就保存在相关的变量中。

# 3 QEMU对象模型 - QOM

> QOM是用C语言实现的一种面向对象的编程模型，QEMU中的所有外设模拟，都是基于QOM来实现的。        

面向对象编程模型中，最重要的概念就是 “类” 了，面向对象的编程就是定义一个类，每个类都代表一类对象。同样，QOM的基础也是 "类"，但它并不像面向对象语言一样，通过关键字来定义类的，而是通过数据结构和函数来定义的：

```c
struct TypeInfo
{   
    const char *name;
    const char *parent;
    
    size_t instance_size; 
    void (*instance_init)(Object *obj);
    void (*instance_post_init)(Object *obj);
    void (*instance_finalize)(Object *obj);

    bool abstract;
    size_t class_size;

    void (*class_init)(ObjectClass *klass, void *data);
    void (*class_base_init)(ObjectClass *klass, void *data);
    void (*class_finalize)(ObjectClass *klass, void *data);
    void *class_data;               
                                    
    InterfaceInfo *interfaces;
};

#define type_init(function) module_init(function, MODULE_INIT_QOM)
```

QOM中用 `TypeInfo` 结构体来定义一个类型，其中：

* `name` 是新类型的名称，`parent` 是新类型所继承的父类型的名称；
* `instance_size` 是新类型对象所占用的内存大小；
* `instance_init/instance_post_init` 可以理解为面向对象中对象的构造函数，`instance_finalize` 为析构函数；
* `class_size` 为新类型的类结构体，所占用的内存大小；
* `class_init/class_base_init` 是新类型的类的初始化函数，`class_finalize` 是类的清除函数。

---

在面向对象编程中，开发者一般只会涉及到对象的构造和析构函数，不会涉及到类型的初始化和清除函数 (这是在语言内部实现的)。要注意，这两者是不同的，类型只存在一个实例，而对象可能同时存在多个实例，QOM需要自己实现类型的初始化和清除等操作。

`type_init` 函数，把新定义的类型注册进系统中。**在QEMU中，维护了一个所有类型的哈希表，**`type_init` 的作用，就是把新类型保存到这个哈希表中，这个哈希表就是系统中定义的所有类型的数据库。实际上这个哈希表中，并不是直接保存的 TypeInfo结构体，而是TypeImpl结构体，`type_init` 函数会把TypeInfo结构的所有字段，都赋值给TypeImpl的相关成员。TypeImpl结构体宏有一个 `class` 成员，当新的类型初始化后 (`class_init` 函数执行完)，该成员将指向新类的类型结构体。

从TypeInfo可以看出，类型和它的对象是两个不同的结构体，而在我们使用面向对象语言的编程中，只需要定义一个类就足够了，没有明显的区分类型和对象的成员，这是因为语言本身自动处理了这个过程。实际上在语言内部是区分了类型和对象的，比如：所有对象都共享的静态成员和函数就是类的成员，保存在类结构体中。QOM没有编程语言的帮助，就只能自身来实现，类结构体和对象结构体了。

面向对象的特点是，类型和对象是相互关联的，且类型是可以继承的，这样我们在引用一个对象的时候，才能调用其类型 (包括父类型) 中定义的函数和变量。QOM也必须实现类型和对象的关联，及父子类型之间的继承关系，这需要借助两个结构体来实现，就是**根类型结构体和根对象结构体。**QOM中并不能随意定义类型，你必须指定一个父类型。**QOM与java类似，是单根的继承结构，所有的类型都有一个共同的祖先，**如下所示：

```c
static TypeInfo object_info = {
    .name = TYPE_OBJECT,
    .instance_size = sizeof(Object),
    .instance_init = object_instance_init,
    .abstract = true,
};  

struct ObjectClass
{
    /*< private >*/
    Type type;
    GSList *interfaces;
    const char *object_cast_cache[OBJECT_CLASS_CAST_CACHE];
    const char *class_cast_cache[OBJECT_CLASS_CAST_CACHE];
    ObjectUnparent *unparent;
    GHashTable *properties;
};

struct Object
{
    /*< private >*/
    ObjectClass *class;
    ObjectFree *free;
    GHashTable *properties;
    uint32_t ref; 
    Object *parent;
};
```

* TYPE_OBJECT类型是所有类型的父类型。可以看到，类型TYPE_OBJECT并没有 `class_init` 函数，但是它有对应的类结构体，就是ObjectClass (在类型初始化时会判断如果是根类型，自动为分配ObjectClass，作为根类型的结构体)。
* ObjectClass的类结构体初始化时，并不需要做特殊的初始化操作，这是自然的，对象Object和类型ObjectClass并没有模拟一个有意义的设备，只是为了构建面向对象继承关系的工具结构体，这意味着ObjectClass类型初始化时，只是分配了一个struct ObjectClass结构体，放在全局类型hash表中。

* Object结构，是所有对象都会从根类型继承的对象成员。Object和ObjectClass结构体，里面的很多成员是为了辅助实现面向对象的操作的。比如，Object对象的class成员指向其对应的类型，这样就把类型和它的对象关联起来了。

---

> **QOM是如何实现继承的呢？**

QOM规定，一个子类型的结构体，必须把它的父类型的结构体放在其第一个成员，这样在子类型结构体中，就可以保存所有的祖先类型定义的成员。相应的，子对象也会把父对象放在其第一个成员，从而实现了继承关系。

* `type_initialize(Type)` 函数，用来初始化一个类型。如果父类没有初始化，就会递归的初始化其父类型。初始化完成后，`type_impl->class` 指向类结构体，在初始化的过程中，父类结构体的字段会被copy到子类中的父类类结构体中。

* `object_new(Type)` 函数，用来初始化一个对象。如果对象的类型没有初始化，它会先初始化类结构体，然后会递归调用父类的 `instance_init` 函数 (先调用父类再调用子类)，与 `instance_post_init` (先调用子类，再调用父类)，来初始化对象。

在QEMU中，每个对象或设备都有一些属性，这些属性有可能是设备的某种状态，也有可能是某个标志等。设备的属性，是通过其类型 (ObjectClass的 `properties` 成员)来定义的，但是具体的属性的值，是保存在对象Object的`properties` 成员的。

---

QEMU的QOM并不是一种编程语言，它主要是用来进行设备模拟的，**QEMU基于QOM定义所有设备的父类：**

```c
static const TypeInfo device_type_info = {
   .name = TYPE_DEVICE,
   .parent = TYPE_OBJECT,
   .instance_size = sizeof(DeviceState),
   .instance_init = device_initfn,
   .instance_post_init = device_post_init,
   .instance_finalize = device_finalize,
   .class_base_init = device_class_base_init,
   .class_init = device_class_init,
   .abstract = true,
   .class_size = sizeof(DeviceClass),
};

typedef struct DeviceClass {
	ObjectClass parent_class;
    DECLARE_BITMAP(categories, DEVICE_CATEGORY_MAX);
    const char *fw_name;
    const char *desc;
    Property *props;
    bool user_creatable;
    bool hotpluggable;
    DeviceReset reset;
    DeviceRealize realize;
    DeviceUnrealize unrealize;
    const struct VMStateDescription *vmsd;
    const char *bus_type;
} DeviceClass;


static void device_class_init(ObjectClass *class, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(class);
    
    class->unparent = device_unparent;
    dc->hotpluggable = true;
    dc->user_creatable = true;
}
```

DeviceClass类型，继承自ObjectClass，它是qemu要模拟的所有设备的父类型，定义了设备的通用属性和方法。

* `parent_class `: 指向父类型的指针；
* `fw_name`: firware名称；
* `propertys`: 在qemu中，每个设备都有各自的属性，以链表的形式，保存在设备的根结构Object的`properties` 字段中。但是每个设备有哪些属性，是在设备的类型中定义的，即这里的 `properties` 字段定义设备有哪些属性，设备类型的继承链上，每个子类型都有可能定义一些属性，在设备初始化时，会遍历设备类型继承链，把所有属性都存放到Object的属性链表中；
* `user_creatable`: 设备是否是可以由用户创建的，QEMU中并不是所有的模拟设备，都是可以由用户通过命令行创建的，有些设备是要QEMU自动创建的，比如sysbus总线设备；
* `hotpluggable`： 设备是否是可插拔的；
* `reset`: 设备复位回调函数；
* `realize`: 设备实例化回调函数。**qemu的设备初始化分为两步：**
* 一个是设备类型中定义的构造函数 `instance_init`，创建设备 `object_new` 时调用；
* 另外一个，是这里的 `realize` 函数，在设备的realized属性被设置为true时调用，`realize` 函数被调用后，设备才是真正的被初始化并变的可用；
* `unrealize`： 与realize回调函数对应，设备清理时调用；
* `VMStateDescription`：该结构体用来保存设备的状态，在虚拟机迁移或冻结时使用；
* `bus_type`：总线类型，在qdev的设备模型中，每个设备都有其挂接的总线；

---

上面介绍了，通用设备类型的一些属性和函数接口，`device_class_init` 对通用设备类型做初始化，它很简单，默认设置设备为，用户创建的和可热插拔的。通用设备类型，定义了所有设备的通用接口，包括设备的属性、reset和realize接口等。

从通用设备类型的定义来看，设备树挂接在总线上的。在物理计算机中，设备都是通过总线连接到计算机上的。总线有两种功能：**一种是为物理设备提供通信通道，另外一种是对总线挂接的设备实施统一的管理。**

在QEMU中，也对总线进行了模拟：

```c
static const TypeInfo bus_info = { 
    .name = TYPE_BUS,
    .parent = TYPE_OBJECT,
    .instance_size = sizeof(BusState),
    .abstract = true,
    .class_size = sizeof(BusClass),
    .instance_init = qbus_initfn,
    .instance_finalize = qbus_finalize,
    .class_init = bus_class_init,
};

struct BusClass {
    ObjectClass parent_class;
    char *(*get_fw_dev_path)(DeviceState *dev);
    void (*reset)(BusState *bus);
    BusRealize realize; 
    BusUnrealize unrealize;
    int max_dev;
    int automatic_ids;
};  

struct BusState {
    Object obj;
    DeviceState *parent;
    char *name;
    HotplugHandler *hotplug_handler;
    int max_index;
    bool realized;
    QTAILQ_HEAD(ChildrenHead, BusChild) children;
    QLIST_ENTRY(BusState) sibling;
};
```

通用总线类型为TYPE_BUS，他是QEMU模拟的其他总线 (比如PCI总线等) 类型的基类。在QEMU中，总线是模拟的，它没法为挂在其上的设备提供通信信道，它主要是实施对设备的管理功能。因此，总线类型中定义的接口和函数都和设备管理相关。

在BusClass结构体中：

* `get_fw_dev_path` 函数指针，是用来获取设备在总线上的位置的，不同的总线有不同的编址方式，因此这里是一个函数接口；
* `reset` 函数接口，是用来复位总线上所有的设备的；
* `realize` 接口是用来实例化总线及其上的所有设备的。

在BusState结构体中：

* `hotplug_handler` 函数接口，是用来处理设备热插拔的；
* `children`，用来挂接总线上的设备的。

---

QEMU对于设备模拟，提供了TYPE_BUS和TYPE_DEVICE两个基类型。这两个基类型，为设备的模拟抽象了一些基础的接口，提供了一个基本的框架：

* **提供了设备属性接口，**设备的属性为QEMU管理或访问设备，提供了一个统一的访问接口，比如要实例化一个设备，只需要调用属性操作接口，设置设备的 `realize` 属性为true就行了。在设备模拟代码中，该属性的处理函数会自动调用具体的实例化函数。每个设备都会定义很多个属性。
* **为设备定义了所有设备都会有的几个通用属性，以及每个设备模拟都要实现的接口函数**，比如 `realize`、`hotplug` 和 `usercreateble` 属性，以及 `reset` 和 `realize` 函数。
* **为设备的统一管理，提供了TYPE_BUS基类型。**设备挂接在总线上，从而虚拟机上所有的设备抽象成一个树型结构，设备之间建立了联系从而构成一个有机整体，也为设备的统一管理操作提供了接口。

QOM和TYPE_DEVICE/TYPE_BUS基类，只是为设备的模拟，提供了一些基础的框架和管理接口。具体设备，是由特定的设备模拟代码实现的，在此框架的基础上还有很多其他的工作要做。

一般情况下，模拟一个设备 (比如e1000网卡) ，需要模拟设备上的所有寄存器接口访问，以及中断处理等设备操作。设备模拟代码，会往虚拟机的地址空间里注册一些回调函数，以在guest驱动访问寄存器时，模拟对寄存器的读写操作，并向CPU注入虚拟中断。

# 4 QEMU: monitor/QMP

monitor/QMP，是用来实现虚拟机管理的。其中对具体设备的管理操作，比如设备状态获取等，就是通过设置或获取设备的属性来实现的。对QEMU的代码入门来说，可以先不管，暂时略过。

# //TODO: 5 QEMU主事件循环

QEMU中的主事件循环，是为QEMU在设备模拟过程中的各个任务，遵循的执行模型或者执行流。在一般持续的C程序中 (比如单片机的程序)，在进行一定的初始化后，都会进入一个while循环，while循环不断的检测执行条件，当条件满足时，就执行循环体里面的任务。QEMU的主事件循环，对应的就是这个while主循环，区别是传统的 “while主循环” 是一个非常原始和粗放的方式，而QEMU的主事件循环要先进的多。

QEMU的主循环，不能采用原始的方式，必须经过精巧的设计呈现出来。这是因为，QEMU对性能的要求很高且QEMU的主循环中要处理非常多的事件，执行非常多的任务，为了协调这些任务的执行，必须采用非常精巧的方式来执行主事件循环。

---

QEMU的主事件循环，是在glib库提供的 `gmainloop` 主事件循环机制的基础上，改造而来的：

* Glib事件循环机制，提供了一套事件分发接口，使用这套接口注册事件源（source）和对应的回调，可以开发基于事件触发的应用。Glib的核心是 `poll` 机制，通过 `poll` 检查用户注册的事件源，并执行对应的回调。用户不需要关注其具体实现，只需要按照要求，注册对应的事件源和回调即可。
* Glib事件循环机制，管理所有注册的事件源，主要类型有：fd，pipe，socket 和 timer。不同事件源可以在一个线程中处理，也可以在不同线程中处理，这取决于事件源所在的上下文（GMainContext）。一个上下文只能运行在一个线程中，所以如果想要事件源在不同线程中并发被处理，可以将其放在不同的上下文。

**Glib对一个事件源的处理分为4个阶段：初始化，准备，poll 和调度。**用户可以在这４个处理阶段，为每个事件源注册自己的回调处理函数：

prepare： gboolean (*prepare) (GSource *source, gint *timeout_);
Glib初始化完成后会调用此接口，此接口返回TRUE表示事件源都已准备好，告诉Glib跳过poll直接检查判断是否执行对应回调。
query：gint g_main_context_query (GMainContext *context, gint max_priority, gint *timeout_, GPollFD *fds, gint n_fds);
Glib在prepare完成之后，可以通过query查询一个上下文将要poll的所有事件。
check：gboolean (*check) (GSource *source);
Glib在poll返回后会调用此接口，用户通过注册此接口判断哪些事件源需要被处理，此接口返回TRUE表示对应事件源的回调函数需要被执行，
dispatch：gboolean (*dispatch) (GSource *source, GSourceFunc callback, gpointer user_data);

Glib根据check的结果调用此接口，参数callback和user_data是用户通过g_source_set_callback注册的事件源回调和对应的参数。

QEMU的在主循环执行的过程中要处理很多的任务，监控非常多的事件，比如QME/monitor的管理命令、IO事件、VNC显示相关事件、操作系统的信号等。QEMU没有把所有的事件都作为一个单独GLIB事件源加入到glib主事件循环中，而是对glib的事件源进行了定制，把要监控的事件都作为一个事件源加入到QEMU主循环中，然后监控这个事件源，对事件进行分发，分发的具体触发事件的任务中去。

我们看看QEMU是怎么对事件源进行定制的。

```c
struct AioContext {
    GSource source;
    QemuRecMutex lock;
    QLIST_HEAD(, AioHandler) aio_handlers;
    uint32_t notify_me;
    QemuLockCnt list_lock;
    struct QEMUBH *first_bh;
    bool notified;
    EventNotifier notifier;
    QSLIST_HEAD(, Coroutine) scheduled_coroutines;
    QEMUBH *co_schedule_bh;
    struct ThreadPool *thread_pool;
    QEMUTimerListGroup tlg;
    int external_disable_cnt;
    int poll_disable_cnt;
    int64_t poll_ns;        
    int64_t poll_max_ns;    
    int64_t poll_grow;      
    int64_t poll_shrink;    
    bool poll_started;
    int epollfd;
    bool epoll_enabled;
    bool epoll_available;
};
```

 AioContext结构体是QEMU定制的事件源，实际上它是把GLIB主事件循环的事件源结构体封装在了其第一个字段：

* source: glib主事件循环的事件源结构体，一个glib主事件循环可以挂接多个事件源，每个事件源都有其对应的处理函数。
  aio_handlers：IO处理事件链表，链表的每个成员代代表了一个IO事件，里面集成了要探测的文件描述符，读写处理函数等。这个QEMU执行IO任务的主要的事件类型。
  notify_me：QEMU对glib事件源进行了封装，最终加入gsource的事件源只有一个，其他所有的事件都是通过这个事件来分发的，这就意味着，QEMU的其他所有事件发生的，都必须发送这个加入gsource的事件，这个事件就是主事件循环的通知事件，通知主循环处理QEMU事件。notify_me字段是个用来优化事件发送的字段，当这个字段被置位时，代表主循环已准备好轮休事件，这时可以向glib循环发送事件，否则，就没有必要发送事件。
  first_bh:QEMU支持的底半部机制，它运用于一些敏感场合不适宜执行大量代码时，这样可以把一些关键代码在敏感场合孩子小，而其他一些不关键的大量代码延后放在底半部里面执行。firt_bh字段存放的是低半部链表中的第一个底半部。
  notified: 代表已经发出通知事件，通知主循环处理。
  notifier:这个就是封装主循环通知事件的结构体，它其实是基于Linux的eventfd实现的。eventfd包含两个文件描述符，一个用于写，一个用于读，向写描述符写入，在读描述符可以读到写入的内容，eventfd机制可用于进程/线程间通信，也可用于内核和用户空间的通信。QEMU把读描述符加入主事件循环的事件源，写描述符用于发出通知，通知主事件循环处理事件。
  scheduled_coroutines和co_schedule_bh两个字段是用来处理协程的，协程也是一种异步执行机制，QEMU的协程是基于底半部实现的。
  tlg:定时器组链表，QEMU支持定时器机制，QEMU的定时器也是用来执行一些定时执行的任务。QEMU定时器也是主事件循环需要处理的一种任务。
  剩下的字段poll、epoll等都是为了高效的监控通知时件而设计的，利用操作系统的poll或epoll等技术实现。

从QEMU定制的事件源来看，QEMU支持４种不同类型的任务即QEMU把其要处理的任务分为了４种不同的类型：iohander是其中最主要的用来处理io任务、低半部用来延迟执行一些不太紧急的任务、协程、定时器任务用来处理一些定时执行的任务。QEMU的任务不是定死的，都是可以根据需要动态的添加到这四中任务类型中。

QEMU主事件循环的初始化函数为qemu_init_main_loop函数。

```c
143 int qemu_init_main_loop(Error **errp)
144 {
145     int ret;
146     GSource *src;
147     Error *local_error = NULL;
148 
149     init_clocks(qemu_timer_notify_cb);
150 
151     ret = qemu_signal_init();
152     if (ret) {
153         return ret;
154     }
155 
156     qemu_aio_context = aio_context_new(&local_error);
157     if (!qemu_aio_context) {
158         error_propagate(errp, local_error);
159         return -EMFILE;
160     }
161     qemu_notify_bh = qemu_bh_new(notify_event_cb, NULL);
162     gpollfds = g_array_new(FALSE, FALSE, sizeof(GPollFD));
163     src = aio_get_g_source(qemu_aio_context);
164     g_source_set_name(src, "aio-context");
165     g_source_attach(src, NULL);
166     g_source_unref(src);
167     src = iohandler_get_g_source();
168     g_source_set_name(src, "io-handler");
169     g_source_attach(src, NULL);
170     g_source_unref(src);
171     return 0;
172 }
```

151行，qemu_signal_init，初始化QEMU进程的信号处理函数，进程总会接收到来自操作系统或其他进程的信号，QEMU把这些信号统一处理，除了必须单独处理的信号外，QEMU把所有信号都加入一个信号集合，并把信号集合转变为一个文件，并把信号处理任务转变为一个iohanders任务放在主事件循环中统一处理。
        156行，初始化一个QEMU定制的事件源，qemu_notify_bh 是主事件循环的一个默认事件源。
        157行，分配了一个GPollFD结构的数组gpollfds，QEMU的主事件循环并没有使用glib提供的轮询处理函数(g_main_loop_run)，而是QEMU自己定制的,这是因为QEMU除了要轮询加入事件glib主循环的事件源外，还要轮训外部的连接事件(比如TCP连接和socker连接等)。这里的gpollfds数组主事件循环poll时的文件描述符，显然，QEMU定制事件源的通知事件eventfd也会加入到这个数组中。
        165行， g_source_attach函数把定制的事件源加入到主循环的默认上下文中。
        167到170行，这里有初始化了一个io-handler的QEMU定制事件源，并加入到主循环默认上下文中。这样主循环中加入了两个事件源:‘“aio-context”和"io-hander"，这两个事件源应该是有各自的分工的。

初始化一个定制事件源的函数为aio_context_new函数：

```c
408 AioContext *aio_context_new(Error **errp)
409 {
410     int ret;
411     AioContext *ctx;
412     
413     ctx = (AioContext *) g_source_new(&aio_source_funcs, sizeof(AioContext));
414     aio_context_setup(ctx);
415 
416     ret = event_notifier_init(&ctx->notifier, false);
417     if (ret < 0) {
418         error_setg_errno(errp, -ret, "Failed to initialize event notifier");
419         goto fail;
420     }
421     g_source_set_can_recurse(&ctx->source, true);
422     qemu_lockcnt_init(&ctx->list_lock);
423         
424     ctx->co_schedule_bh = aio_bh_new(ctx, co_schedule_bh_cb, ctx);
425     QSLIST_INIT(&ctx->scheduled_coroutines);
426     
427     aio_set_event_notifier(ctx, &ctx->notifier,
428                            false,
429                            (EventNotifierHandler *)
430                            event_notifier_dummy_cb,
431                            event_notifier_poll);

437     timerlistgroup_init(&ctx->tlg, aio_timerlist_notify, ctx);
439     ctx->poll_ns = 0;
440     ctx->poll_max_ns = 0;
441     ctx->poll_grow = 0;
442     ctx->poll_shrink = 0;
448 }
```

 413行，申请一个glib事件源。
        414行，如果支持EPOLL的话，申请epoll结构体.
        415行，初始化通知事件的结构体，其实就是创建eventfd。
        424，425行，初始化协程相关结构体。
        427行，设置通知事件，它会把通知事件的读描述符封装成一个AioHander，提供该事件的poll函数，然后把读描述符号使用g_source_add_poll函数把该读描述符加入到glib事件源的poll描述符集合中，这样主事件循环在执行的时候就会轮询该描述符号。
        437~442行，初始化定时器和poll的参数。

QEMU的主事件循环函数为main_loop函数：

```c
1844 static void main_loop(void)
1845 {  
1849     while (!main_loop_should_exit()) {
1853         main_loop_wait(false);
1857     }
1858 }
```

QEMU的主循环不是无限循环，而是有退出条件的，main_loop_should_exit函数判断是否应该退出QEMU，比如监控的reset和关机命令时，需要退出主循环。main_loop_wait是主循环的主要处理过程，除了监控外部连接外，处理glib的主循环事件的函数为os_host_main_loop_wait函数。

```c
221 static int os_host_main_loop_wait(int64_t timeout)
222 {
223     GMainContext *context = g_main_context_default();
224     int ret;
226     g_main_context_acquire(context);

228     glib_pollfds_fill(&timeout);

230     qemu_mutex_unlock_iothread();
231     replay_mutex_unlock();

233     ret = qemu_poll_ns((GPollFD *)gpollfds->data, gpollfds->len, timeout);

235     replay_mutex_lock();
236     qemu_mutex_lock_iothread();

238     glib_pollfds_poll();
240     g_main_context_release(context);
242     return ret;
243 }
```

228行，QEMU的主循环没有采用glib的主事件循环的g_main_loop_run函数，而是自己定制的，但是主循环有必须轮询和监控glib的事件源，所以必须把要事件源中要轮询的文件描述符取出来，加入gpollfds数组中(从前文分析知，该数组里保存的就是QEMU主循环中要轮询的文件描述符)。
        233行，qemu_poll_ns函数就是会调用poll系统调用或者glib库中的轮询函数，轮询gpollfds数组中的每个描述符的状态.
        238行， glib_pollfds_poll函数会根qemu_poll_ns函数poll文件描述符的状态，调用glib循环g_main_context_check和g_main_context_dispatch函数分发事件到具体的处理函数上去，这两个函数实际上会调用glib的事件源里面注册的回调函数，在QEMU中分别是aio_ctx_check和aio_ctx_dispatch函数。
        aio_ctx_check函数检查所有注册的AioHanders有没有准备好的，所有的底半部有没有被调度的，定时器有没有被到期的，如果有就检查成功。aio_ctx_dispatch函数则执行准备好的AioHanders，被调度的底半部函数以及到期的定时器。
        QEMU的主事件循环是在glib主事件循环的基础上定制而成的，它在glib主事件循环的基础上定制了事件源，提供了AioHanders、定时器和底半部等机制来执行相应的任务。















