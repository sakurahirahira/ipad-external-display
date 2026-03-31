# iPad外部ディスプレイ化 設計ドキュメント

## 概要

会社のWindows PCにiPadをUSB-C接続し、外部ディスプレイとして使用する。

## 制約条件

| 制約 | 内容 |
|------|------|
| Win側ソフトインストール | 不可 |
| USBメモリ持ち込み | 不可 |
| 使用可能な手段(Win側) | PowerShell + .NET標準ライブラリ |
| iPad側開発環境 | Mac + Xcode あり |
| 接続方式 | USB-Cテザリング経由TCP/IP |
| 目標フレームレート | 60fps |
| 目標解像度 | 1080p（段階的に） |

## アーキテクチャ

```
Windows PC (PowerShell)              iPad (Swift)
┌────────────────────────┐          ┌────────────────────────┐
│                        │          │                        │
│  画面キャプチャ         │          │  TCP受信               │
│    ↓                   │  USB-C   │    ↓                   │
│  エンコード            │ テザリング │  デコード              │
│    ↓                   │ TCP/IP   │    ↓                   │
│  TCP送信        ───────┼────────→ │  全画面表示            │
│                        │          │    ↓                   │
│  マウス/KB操作   ←─────┼──────────┤  タッチ→入力イベント送信│
│                        │          │                        │
└────────────────────────┘          └────────────────────────┘
```

### 通信経路

iPadの「インターネット共有（テザリング）」をONにしてUSB-C接続。
Windows側からはネットワークアダプタとして認識され、追加ドライバ不要でTCP/IP通信が可能。

### USB NCMテザリング帯域

実用帯域: 約20-40 Mbps

## 段階的開発計画

### Phase 1: プロトタイプ（まず動くもの）

- **目標**: 720p / 10-15fps
- **キャプチャ**: `System.Drawing.Graphics.CopyFromScreen()`
- **圧縮**: JPEG（System.Drawing, 低品質）
- **通信**: `System.Net.Sockets.TcpClient/TcpListener`
- **Win側**: PowerShell 約200行（Add-Type C#インライン）
- **iPad側**: Swift + UIKit, TCPサーバーで受信 → UIImageView表示

### Phase 2: キャプチャ高速化

- **目標**: 720p / 25-30fps
- **キャプチャ**: DXGI Desktop Duplication API（C# P/Invoke）
- **圧縮**: JPEG（差分フレーム送信で帯域削減）
- **Win側**: C# 約500行（Add-Type）

### Phase 3: 60fps到達

- **目標**: 1080p / 60fps
- **キャプチャ**: DXGI Desktop Duplication
- **エンコード**: Media Foundation H.264 MFT（COM interop, GPUハードウェアエンコード）
- **iPad側デコード**: VideoToolbox（H.264ハードウェアデコード）
- **Win側**: C# 約1500行（Add-Type）

Media Foundation H.264エンコーダはWindows 10/11標準搭載（mf.dll, mfplat.dll）。
インストール不要でGPUエンコードが利用可能。

## 帯域計算

| 構成 | 必要帯域 | USB NCMで可能か |
|------|---------|----------------|
| 1080p 無圧縮 60fps | ~3 Gbps | 不可 |
| 1080p JPEG Q50 60fps | ~2.4 Gbps | 不可 |
| 720p JPEG Q20 60fps | ~19 Mbps | ギリギリ |
| 1080p H.264 60fps | 5-15 Mbps | 余裕 |

## Win側 技術スタック（全てインストール不要）

| 機能 | 使用API | 備考 |
|------|---------|------|
| 画面キャプチャ(Phase1) | System.Drawing.Graphics | .NET標準 |
| 画面キャプチャ(Phase2-3) | DXGI OutputDuplication | P/Invoke, DirectX標準搭載 |
| 映像エンコード(Phase1-2) | System.Drawing JPEG | .NET標準 |
| 映像エンコード(Phase3) | Media Foundation MFT | COM, OS標準搭載 |
| TCP通信 | System.Net.Sockets | .NET標準 |
| マウス操作 | user32.dll SendInput | P/Invoke |

## iPad側 技術スタック

| 機能 | 使用フレームワーク |
|------|------------------|
| TCP通信 | Network.framework (NWListener/NWConnection) |
| 映像デコード(Phase1-2) | UIImage(data:) |
| 映像デコード(Phase3) | VideoToolbox (VTDecompressionSession) |
| 画面表示 | UIKit / Metal |
| タッチ入力送信 | UIGestureRecognizer → TCP送信 |

## ファイル構成（予定）

```
6011_iPad外部ディスプレイ化/
├── DESIGN.md                  ← 本ファイル
├── win/
│   └── screen-sender.ps1      ← PowerShellスクリプト（Win側全部入り）
└── ipad/
    └── ExternalDisplay/       ← Xcodeプロジェクト
        ├── ScreenReceiver.swift
        ├── TouchSender.swift
        └── ...
```

## 実測結果（開発環境: 2560x1440 -> 1280x720, Wi-Fi TCP）

| バージョン | 方式 | FPS | キャプチャ | エンコード | 送信 | 備考 |
|-----------|------|-----|-----------|-----------|------|------|
| v1 | CopyFromScreen + JPEG | 10 | 80-100ms | 15ms | 0.1ms | 毎フレームBitmap生成 |
| v2 | CopyFromScreen + バッファ再利用 | 12-15 | 50-90ms | 13ms | 0.1ms | バッファ再利用 |
| v3 | StretchBlt + DIBSection | 20 | 45ms | 4-5ms | 0.1ms | 共有メモリでコピー不要 |
| v4 | v3 + パイプライン | 21 | 35-50ms | 4-5ms | 0.1ms | キャプチャとエンコード並行 |

### ボトルネック分析
- GDI StretchBltがDWMのvsyncに同期するため35-50msかかる
- エンコード（4ms）と送信（0.1ms）はほぼ問題なし
- **GDI方式の理論上限: 約25fps**
- 60fps到達にはDXGI Desktop DuplicationまたはWindows.Graphics.Captureが必要

## 未確認事項

- [x] 会社PCにffmpegが入っているか → 開発PCにはある（8.0.1）が本番PCにはない
- [ ] テザリング接続時のiPadのローカルIPアドレス体系（通常172.20.10.x）
- [ ] 会社PCのGPU種類（Media FoundationのH.264 MFT対応状況に影響）
- [ ] 会社PCにPowerShell 7が入っているか
- [ ] 会社のセキュリティポリシーでPowerShellスクリプト実行が許可されているか（ExecutionPolicy Bypass で回避可能か）
