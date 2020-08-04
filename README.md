# TTAnalyzeLoadTime
通过Mach-O文件NonlazyClassList构建动态库进行iOS load方法耗时检测

## How To Get Started
#### 简介
* 仓库中提供了源码以及二进制的文件，源码提供了整个AnalyzeLoadTime的全部文件`TTLoadTime.mm`,二进制文件为一个动态库（为什么提供动态库文末有介绍），动态库为尽可能提前执行Load Method Swizzling提供了可能
* 重写`_getObjc2NonlazyCategoryList `、`_getObjc2NonlazyClassList `(runtime源码中有介绍),可以快速拿到全部load的所属Class以及load 的IMP地址
* 防止运行环境被破坏使用`method_setImplementation`构建block执行原函数
* 寻找mach-o中的load以及Swizzle共耗时4毫秒


#### Podfile

To integrate TTAnalyzeLoadTime into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'
platform :ios, '8.0'

target 'TargetName' do
pod 'TTAnalyzeLoadTime', '~> 1.0'
end
```

Then, run the following command:

```bash
$ pod install
```

#### Usage

```ruby
#import <TTLoadTime/TTLoadTime.h>

printLoadCostsInfo();

2018-12-14 17:57:48.838908+0800 TTAnalyzeLoadTime_Example[10937:6344725] >> all load cost info below :
2018-12-14 17:57:48.838934+0800 TTAnalyzeLoadTime_Example[10937:6344725] 
2018-12-14 17:57:48.838953+0800 TTAnalyzeLoadTime_Example[10937:6344725] PodLoadTime - 0.005083391442894936ms
2018-12-14 17:57:48.838962+0800 TTAnalyzeLoadTime_Example[10937:6344725] PodLoadTime(LoadTimer) - 0.005166628398001194ms
2018-12-14 17:57:48.838968+0800 TTAnalyzeLoadTime_Example[10937:6344725] TTViewController - 0.02345838584005833ms
2018-12-14 17:57:48.838974+0800 TTAnalyzeLoadTime_Example[10937:6344725] TTViewController(LoadTimer) - 0.005333335138857365ms
2018-12-14 17:57:48.838980+0800 TTAnalyzeLoadTime_Example[10937:6344725] 
```

感谢原作者 0->1 的贡献

