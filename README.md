<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="SimpleVoiceInput icon">
</p>

<h1 align="center">SimpleVoiceInput</h1>

<p align="center">
  一款 macOS 平台的语音输入应用，是 Typeless 的免费替代品。
</p>

<p align="center">
  <a href="https://github.com/hemengfei2014-stack/simple-voice-input/releases/latest/download/SimpleVoiceInput.dmg"><b>⬇ 下载 SimpleVoiceInput.dmg</b></a><br>
  <sub>支持 Apple Silicon (M1/M2/M3) + Intel</sub>
</p>

---

## 功能介绍

SimpleVoiceInput 是一款 macOS 菜单栏语音输入应用，按住 Fn 键即可开始录音，松开后自动将语音转录为文本并粘贴到光标位置。

**核心功能：**
- 按住 `Fn` 键开始录音，松开自动转录
- 使用 Google Gemini API 进行语音识别和文本处理
- 自动粘贴到当前应用的光标位置
- 菜单栏应用，不干扰工作流

## 使用说明

### 安装

1. 下载最新版本的 [SimpleVoiceInput.dmg](https://github.com/hemengfei2014-stack/simple-voice-input/releases/latest/download/SimpleVoiceInput.dmg)
2. 双击打开 DMG 文件
3. 将 `SimpleVoiceInput.app` 拖拽到 `Applications` 文件夹
4. 首次运行需要右键点击应用 → 选择"打开"

### 配置

首次运行需要完成以下配置：

1. **获取 API Key**
   - 访问 [Google AI Studio](https://aistudio.google.com/app/apikey)
   - 创建免费的 Gemini API Key

2. **授予权限**
   - 麦克风权限（用于录音）
   - 辅助功能权限（用于自动粘贴文本）

3. **在应用中配置**
   - 点击菜单栏图标
   - 输入 Gemini API Key
   - 点击测试验证配置

### 使用方式

1. 确保应用正在运行（菜单栏会显示图标）
2. 将光标放在要输入文本的位置
3. **按住 `Fn` 键**开始录音
4. 对着麦克风说话
5. **松开 `Fn` 键**，应用会自动转录并粘贴文本

## 系统要求

- macOS 13.0 或更高版本
- Apple Silicon (M1/M2/M3) 或 Intel 处理器
- 网络连接（用于调用 Gemini API）

## 致谢

本项目参考并借鉴了 [FreeFlow](https://github.com/zachlatta/freeflow) 的实现，感谢原作者的创意和开源贡献。

## 许可证

MIT License
