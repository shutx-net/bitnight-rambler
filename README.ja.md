# Bitnight Rambler

[English](README.md) | 日本語

ターミナルの端を歩き回る、小さなピクセルアートの rambler たち。

`rambit` は Zig で書かれた小さなアニメーションエンジンで、標準ライブラリ以外に依存するものはありません。スプライトはただのテキストファイルなので、新しい rambler はコードではなくデータです。

![3 つのターミナルを歩き回る猫、スライム、ゴースト](docs/demo.gif)

> **ステータス:** 概念実証の段階です。設計の目標は [ABSTRACT.md](ABSTRACT.md)（英語）を参照してください。

## インストール

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sh
```

すべての組み込み rambler を含んだ静的バイナリ 1 つを `~/.local/bin/rambit` としてインストールします。sudo は不要で、シェルの起動ファイルを書き換えることもありません。`~/.local/bin` が `PATH` にない場合は、何を追加すればよいかを表示します。Linux の x86_64 と aarch64（ディストリビューションは問わず、WSL2 を含みます。カーネル 5.10 以降向けにビルドしています）と、macOS 13 以降（Intel と Apple シリコン）で動作します。

何かをインストールする前に、インストーラーは次の点を確認します。

1. リリースの `SHA256SUMS` の署名（ECDSA P-256）。公開鍵は `install.sh` 自体に書き込まれています。
2. `SHA256SUMS` と照合したバイナリの SHA-256。
3. `gh` がインストールされログイン済みの場合は、バイナリの GitHub ビルド来歴アテステーション（Sigstore）。このリポジトリのリリースワークフローから、リリースのタグをもとに GitHub ホストのランナーでビルドされたものでなければなりません。
4. `rambit --version` が要求されたリリースを示すこと。これにより、署名済みの古いリリースが新しいリリースになりすますことはできません。

確認に失敗した場合は何もインストールされません。`curl` と `openssl`（macOS のように LibreSSL でも動作します）が必要で、どちらかがなければ中止します。

自分のユーザーで実行してください。`sudo` や `doas` の下では、ホームに root 所有の `~/.local/bin` を残してしまうため、ディレクトリを指定しない限り実行を拒否します。全ユーザー向けにインストールするには次のようにします。

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sudo env RAMBIT_INSTALL_DIR=/usr/local/bin sh
```

| 変数 | 意味 |
| -------- | ------- |
| `RAMBIT_VERSION` | インストールするリリース。例: `v0.2.0` または `0.2.0`。デフォルトは最新版です。 |
| `RAMBIT_INSTALL_DIR` | `~/.local/bin` の代わりにインストールする先の絶対パスのディレクトリ。 |
| `RAMBIT_SKIP_ATTESTATION=1` | `gh` によるアテステーションの確認を省略します。GitHub のアテステーションサービスが停止しているときなどに使います。署名と SHA-256 は引き続き確認されます。 |
| `RAMBIT_INSECURE_SKIP_SIGNATURE=1` | `openssl` がインストールされていない場合に限り、SHA-256 の確認だけでインストールします。これで検出できるのは破損したダウンロードで、改ざんされたリリースは検出できません。`openssl` がインストールされている場合は無視されるので、不正な署名が見逃されることはありません。 |
| `RAMBIT_DOWNLOAD_BASE` | テスト用: GitHub の代わりにリリースをダウンロードする `https://` または `file://` の URL。`RAMBIT_VERSION` が必要です。署名は引き続き埋め込みの鍵で確認されます。 |

バージョンを固定するには、`RAMBIT_VERSION` を `curl` ではなく `sh` に対して設定します。

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | RAMBIT_VERSION=v0.2.0 sh
```

実行する前にスクリプトを読むには、先にダウンロードします。

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh
less install.sh
sh install.sh            # sh install.sh --help lists the options
```

### 手動での検証

同じ確認を自分で行うこともできます。リリースから自分のマシン用のバイナリ（`rambit-x86_64-linux`、`rambit-aarch64-linux`、`rambit-x86_64-macos` または `rambit-aarch64-macos`）と `SHA256SUMS`、`SHA256SUMS.sig` をダウンロードし、`install.sh` から公開鍵を取り出します。

```sh
v=v0.2.0
base=https://github.com/shutx-net/bitnight-rambler/releases/download/$v
curl -fsSL -O "$base/rambit-x86_64-linux" -O "$base/SHA256SUMS" -O "$base/SHA256SUMS.sig"
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh |
  sed -n '/^-----BEGIN PUBLIC KEY-----$/,/^-----END PUBLIC KEY-----$/p' > rambit-release.pem
```

次に、署名（`Verified OK` と表示されます）、ハッシュ、そして `gh` があればアテステーションを確認します。

```sh
openssl dgst -sha256 -verify rambit-release.pem -signature SHA256SUMS.sig SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS    # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
gh attestation verify rambit-x86_64-linux --repo shutx-net/bitnight-rambler \
  --signer-workflow shutx-net/bitnight-rambler/.github/workflows/release.yml \
  --source-ref "refs/tags/$v" --deny-self-hosted-runners
```

3 つともすべて通ったら、`rambit` という名前でインストールします。

```sh
chmod +x rambit-x86_64-linux
mkdir -p ~/.local/bin && mv rambit-x86_64-linux ~/.local/bin/rambit
```

macOS 用のバイナリは公証（notarization）されていません。`curl` でダウンロードしたファイルは隔離（quarantine）されないので macOS はそのまま実行します。ブラウザでダウンロードしたものは隔離されるので、`xattr -d com.apple.quarantine <file>` で実行できるようになります。

### アンインストール

```sh
rm ~/.local/bin/rambit     # or rambit in your RAMBIT_INSTALL_DIR
```

rambit はほかにファイルを書き込みません。

### 何を信頼することになるか

署名によって、署名後に変更されたリリースファイルや、途中で壊れたダウンロードを検出できます。ただし、このリポジトリそのものからは守ってくれません。鍵を含む `install.sh` はリリースと同じリポジトリから取得されるので、`main` を変更できる人は鍵も変更できます。結局のところ、信頼の対象は GitHub と、このリポジトリを保守する人々です。秘密鍵はオフラインと、リリースワークフローの署名ステップだけが読める GitHub シークレットに保管されています。アテステーションはこの鍵に依存しません。各バイナリを、それをビルドしたワークフローの実行、タグ、コミットに結び付けます。また、リリースワークフローは、何かに署名する前に、Linux と macOS でのビルドがバイト単位で同一であることを確認します。リリースの作り方は[docs/RELEASING.md](docs/RELEASING.md)（英語）に記載しています。

## ビルド

[Zig 0.16.0](https://ziglang.org/download/) が必要です。

```sh
zig build                          # builds zig-out/bin/rambit
zig build run -- cat               # builds and runs
zig build test                     # unit tests, including every built-in rambler
zig build validate                 # rambit validate ramblers
zig build -Doptimize=ReleaseSmall  # a standalone binary of under 300 KB
zig build -Dversion=0.2.0-dev      # report another version than build.zig.zon's
tools/build-release.sh dist        # the four release binaries and SHA256SUMS
```

`rambit --version` は、`-Dversion` で別のバージョンを指定しない限り `build.zig.zon` のバージョンを表示します。バージョンはセマンティックバージョンでなければなりません。`tools/build-release.sh` は、どのホストからでもリリース用のバイナリをクロスビルドし、Linux と macOS で同じバイト列を生成します。リリースの署名と公開の方法は [docs/RELEASING.md](docs/RELEASING.md)（英語）にあります。

Linux でテストしています。CI では macOS でも擬似端末のものを含めてテストを実行していますが、rambit を macOS で手動で試したことはまだありません。ネイティブの Windows には対応していません。WSL 上では Linux と同じように動作します。

### Nix を使う場合

flake は x86_64-linux、aarch64-linux、aarch64-darwin 向けに Zig 0.16.0 と ZLS を提供します。

```sh
nix develop          # a shell with zig and zls
direnv allow         # or let direnv load it whenever you cd in (.envrc)
nix build            # ./result/bin/rambit, after running the tests
nix run . -- cat
nix flake check
```

## 使い方

```sh
rambit cat              # q, Esc or Ctrl-C sends it home
rambit slime --once     # cross the bottom once and exit, like sl
rambit ghost --seed 42  # the same seed gives the same stroll
rambit list             # the built-in ramblers
rambit preview cat      # print every frame, e.g. to review a pull request
rambit validate         # check the built-in ramblers, or given directories
rambit shell            # your shell, with a rambler roaming over it
rambit shell slime      # the same, starting with the slime
rambit shell -- top     # a command instead of the shell
```

| オプション | 意味 |
| ---------------- | ------------------------------------------------------------ |
| `--once`         | 画面の下端に沿って一度だけ横切り、終了します。 |
| `--seed <n>`     | 動きのシードを指定し、実行を再現できるようにします。 |
| `--color <mode>` | `auto`（デフォルト）、`truecolor` または `256`。`auto` は `COLORTERM` が `truecolor` か `24bit` のとき 24 ビットカラーを使います。 |

rambler は `less` や `vim` のように代替スクリーンで動くので、rambler が去った後のターミナルは元どおりの見た目になります。

### rambler のいるシェル

`rambit shell` は、tmux や screen と同じように、擬似端末上でシェル（`$SHELL`、未設定なら `/bin/sh`）または `--` の後のコマンドを実行します。プログラムの画面を自前で保持し、その上に rambler を描き、変化したセルだけを書き出します。プログラムが終了すると rambit もプログラムの終了ステータスで終了します。シグナルで終了させられた場合は 128 にシグナル番号を足した値になります。実行できないコマンドは画面が切り替わる前に報告され、シェルと同じく、見つからない場合はステータス 127、それ以外は 126 になります。

セッションは代替スクリーンで動くので、表示されていた内容は終了時に消え、ターミナルは元どおりの見た目になります。スクロールバックはありません。tmux と同じく、上端からスクロールして出た内容は失われ、ターミナル自身のスクロールバーにも残りません。

`--seed` と `--color` は `rambit <name>` と同じように使えます。`--once` は適用されません。Ctrl-] に続くコマンドキーを除き、Ctrl-C や Esc も含めてすべてのキーはプログラムに送られます。

| キー | 動作 |
| ----------------- | ------------------------------------------------------ |
| `Ctrl-]` `h`      | rambler を隠す、または表示します。 |
| `Ctrl-]` `n`      | 次の rambler を呼び出します。 |
| `Ctrl-]` `Ctrl-]` | Ctrl-] をプログラムに送ります。 |

最初に登場するのは指定した rambler、指定がなければ最初の組み込み rambler で、`Ctrl-]` `n` でほかの組み込み rambler を順にたどり、最後まで行くと最初に戻ります。Ctrl-] の後のそれ以外のキーは、矢印キーや Alt との組み合わせも含めて捨てられます。Ctrl-] は telnet のエスケープキーです。readline や emacs が使う tmux の Ctrl-b や screen の Ctrl-a と違い、シェルのキー割り当てを奪いません。vim はこのキーでタグジャンプしますが、2 回押せば引き続き使えます。プログラムがブラケットペーストを有効にしている間に貼り付けたテキストは、Ctrl-] も含めてそのまま渡されます。

rambler はいつもどおりテキストの上で画面の端を歩き回りますが、入力内容を隠さないように、カーソルのある行には入りません。キーを押してから 2 秒間は、カーソルの上下 2 行も空けておきます。カーソルが最下行にあるときは、壁を登れる rambler は角から入ってきて壁を登ります。床しか歩かない rambler は、場所が空くまで画面外で待ちます。

セッション内では `RAMBIT_SHELL=1` が設定されます。`rambit shell` は、これが設定されている環境では入れ子にせず、起動を拒否します。

#### シェルモードの仕組み

- **`TERM=xterm-256color`。** キーはターミナルが送るとおりにそのまま渡され、そのターミナルはほぼ必ず xterm 互換なので、プログラムには xterm 互換のターミナルだと伝えます。エミュレーターは、この terminfo エントリが示す機能を実装しています。背景色消去（BCE）、ECH、REP、スクロール領域、行と文字の挿入と削除、イタリック、1049 の代替スクリーン、DEC 罫線文字です。pty のサイズが使われるように、`LINES` と `COLUMNS` は取り除かれます。`COLORTERM` はそのまま渡され、rambit 自身が 256 色を使っている場合（`--color` を参照）、24 ビットカラーは 256 色のうち最も近い色になります。
- **モードと応答。** プログラムが設定したカーソルキー、キーパッド、ブラケットペーストの各モードはターミナルにも反映され、rambit の終了時にリセットされます。ステータス、カーソル位置、デバイス属性の問い合わせ（DSR、DA）には応答し、ベルはそのまま通します。マウスレポート、フォーカスイベント、同期出力は無視され、ウィンドウタイトルやハイパーリンクのような OSC、DCS、APC 文字列も無視されます。
- **全角文字。** 東アジアの wide 文字と fullwidth 文字は 2 セルを占めます。これは `tools/width_table.py` が Python の `unicodedata`（Unicode 14.0）から生成する表に、glibc にあるいくつかの追加の wide 範囲を加えたものに基づいており、Unicode 14 までは glibc の `wcwidth` と一致します。幅が曖昧な文字は 1 セルを占め、結合文字は捨てられます。非 ASCII 文字の後では rambit が実際のカーソルを明示的に移動するので、ターミナルと幅の解釈が食い違っても行の残りがずれることはありません。
- **解析。** パーサーは Paul Williams による DEC 端末の状態機械に従い、UTF-8 をデコードします。不正なバイトには U+FFFD を表示します。0x80 から 0x9F のバイトを C1 制御文字として扱うことはありません。
- **リサイズ。** 新しいサイズは pty に渡され、カーネルが `SIGWINCH` でプログラムに通知します。内容の再配置（リフロー）は行いません。カーソルのある行は表示範囲内に保たれるので、最下行のプロンプトは最下行のままです。
- **スループット。** pty はプログラムが書き込む速さで読み取られ、画面の描画は最大で毎秒 30 回なので、大きなファイルを `cat` してもターミナルのせいで待たされることはありません。
- **終了。** `SIGINT`、`SIGTERM`、`SIGHUP` を受け取ると、rambit はターミナルのウィンドウを閉じたときと同じようにプログラムにハングアップを送り、数秒後もまだ残っていれば強制終了します。
- **プラットフォーム。** Linux では、rambit は ioctl で `/dev/ptmx` を開き、libc を必要としません。macOS では、すべての macOS プログラムがリンクする libSystem の `posix_openpt` などを使い、`select(2)` で待機します。macOS では `poll(2)` が端末に対して機能しないためです。

## rambler の追加

`ramblers/` の下にディレクトリを作ります。ビルド時にそこにあるすべてのディレクトリが埋め込まれるので、コードを変更する必要はありません。

```text
ramblers/cat/
├── manifest.json
├── idle-0.sprite
├── walk-0.sprite
└── ...
```

埋め込まれるのは `manifest.json` と `.sprite` ファイルだけです。README やクレジットなど、ディレクトリ内のそれ以外のものはビルド時に無視されます。

描いている間は、再ビルドせずにディレクトリから直接実行できます。

```sh
rambit preview ./ramblers/cat   # every frame side by side
rambit ./ramblers/cat           # the real thing
rambit validate ramblers/cat    # what is wrong, with file:line:column
```

### manifest.json

```json
{
  "id": "cat",
  "name": "Cat",
  "description": "A little tabby that strolls around the edges of your terminal.",
  "width": 16,
  "height": 12,
  "facing": "right",
  "palette": {
    "k": "#3b2730",
    "o": "#f2a65a",
    "d": "#c8743a",
    "w": "#ffe9c7",
    "p": "#f497a9"
  },
  "animations": {
    "idle": { "frames": ["idle-0", "idle-0", "idle-0", "idle-1", "idle-0", "idle-0", "idle-2", "idle-2"], "frame_ms": 400 },
    "walk": { "frames": ["walk-0", "walk-1", "walk-2", "walk-3"], "frame_ms": 140 },
    "run": { "frames": ["run-0", "run-1"], "frame_ms": 110 },
    "sleep": { "frames": ["sleep-0", "sleep-1"], "frame_ms": 800 },
    "jump": { "frames": ["run-1", "run-0"], "frame_ms": 120 }
  },
  "wall_animations": {
    "walk": { "frames": ["climb-0", "climb-1", "climb-2", "climb-3"], "frame_ms": 160 },
    "jump": { "frames": ["climb-1", "climb-0"], "frame_ms": 120 }
  },
  "ceiling_animations": {
    "walk": { "frames": ["ceiling-walk-0", "ceiling-walk-1", "ceiling-walk-2", "ceiling-walk-3"], "frame_ms": 140 }
  },
  "motion": { "speed": 9, "run_speed": 20 }
}
```

| フィールド | 必須 | 意味 |
| -------------- | -------- | ------- |
| `id`           | はい | 小文字の英字、数字、`-`。ディレクトリ名と一致する必要があります。 |
| `name`         | はい | 表示名。 |
| `description`  | いいえ | `rambit list` で表示されます。 |
| `width`, `height` | はい | すべてのフレームのピクセル単位のサイズ。1 から 64。 |
| `facing`       | いいえ | `right`（デフォルト）または `left`。フレームが描かれている向きです。反対向きには自動的に左右反転されます。 |
| `palette`      | はい | 1 文字の記号と `#rrggbb` の色の対応。 |
| `animations`   | はい | 床でのアニメーション: `idle`、`walk`、`run`、`sleep`、`jump`。`idle` と `walk` の少なくとも一方が必要で、それぞれもう一方で代用されます。ほかは省略可能です。 |
| `wall_animations` | いいえ | 同じ種類と規則で、壁用のもの。これがあると rambler は壁を登ります。 |
| `ceiling_animations` | いいえ | 同様に、天井用のもの。天井へは壁を通って行くので、`wall_animations` も必要です。 |
| `edges`        | いいえ | 歩く端: `bottom`、`left`、`right`、`top` のいずれか。`bottom` を含む必要があります。壁には `wall_animations` が、`top` には `ceiling_animations` と、`left` または `right` が必要です。デフォルトは、rambler にアニメーションがあるすべての端です。 |
| `frames`       | はい | `.sprite` を除いたスプライトのファイル名。同じ名前を繰り返すと、そのフレームを長く表示します。 |
| `frame_ms`     | いいえ | 1 フレームあたりのミリ秒数。20 から 10000。デフォルトは 150。 |
| `motion.speed` | いいえ | 毎秒のピクセル数（ターミナルの列数）。1 から 64。デフォルトは 8。 |
| `motion.run_speed` | いいえ | 走っているときの毎秒のピクセル数。1 から 64。デフォルトは `speed` の 2 倍で、最大 64。 |
| `motion.jump_height` | いいえ | ジャンプの高さ（ピクセル）。1 から 64。デフォルトは `height` の半分で、最小 1。 |

`walk` は rambler が移動している間、`idle` は休んでいる間に再生されます。ほかの 3 つは省略可能で、rambler はアニメーションがある動作だけを行います。`run` があるとときどき `run_speed` で走り出し、`sleep` があると休憩の一部が長めの昼寝で終わり、`jump` があると移動中にときどき `jump_height` ピクセル跳び上がります。`jump` は踏み切るたびに最初のフレームから始まり、rambler が着地するまで最後のフレームを保ちます。`idle` がない rambler は休みませんが、`sleep` があればたまに止まって昼寝をします。`--once` では、rambler は歩くだけで、下端に沿ってしか移動しません。rambler に脚は必要ありません。スライムは跳ね、ゴーストは漂いますが、どちらも同じ `walk` アニメーションを使っています。

`wall_animations` があると rambler は壁も登り、さらに `ceiling_animations` もあると天井を横切るので、すべての端があれば画面をぐるりと一周できます。rambler は必ず下端から入ってきて、角を回ってある端から次の端へ移ります。それぞれの端ではその面のアニメーションを使い、休む、眠る、走る、跳ぶのはその面にアニメーションがある場合だけです。`idle` と `walk` は同じセットの中で互いに代用され、`run` がない面へ角を回ると、走りは歩きに変わります。ジャンプは端から離れて画面の中央に向かい、角を回ることはありません。たとえば猫は壁では登ったり跳んだりしますが、天井では歩くだけなので、休んだり眠ったりするのは床の上だけです。

### スプライト

ピクセルの 1 行につきテキスト 1 行です。`.` は透明で、ターミナル自身の背景が見えます。それ以外の文字はすべてパレットにある必要があります。

```text
..........k...k.
.k.......kpkkkpk
kok......koooook
kok......kokokok
```

ターミナルの各セルには縦に並んだ 2 ピクセルが表示されるので、16×12 のスプライトは 16 列 6 行を占めます。

#### 壁と天井のフレーム

フレームが回転されることはありません。エンジンが行うのは左右反転と上下反転だけです。床のフレームを 90 度回転させると、登っている rambler が横倒しになり、光の当たり方もおかしくなります。そのため面ごとに専用のフレームがあり、その面での見た目どおりに rambler を描きます。

壁のフレームは幅 `height` ピクセル、高さ `width` ピクセルです。右側の壁を上に向かって進む姿を、壁を右にして描きます。猫は前足を壁につけて登り、ゴーストは背中を壁に向けて漂い上がります。左の壁用には左右反転され、下りでは上下反転されるので、どちら向きでも読み取れる顔にしておくと便利です。スライムは目の高さをそろえ、ゴーストは壁の上では口を平らにしています。

天井のフレームは床のフレームと同じく幅 `width`、高さ `height` で、画面の上端に接したときの見た目どおりに、`facing` の向きで描きます。反対向きには左右反転されますが、上下反転はされないので、それは描き手次第です。猫は逆さまに歩き、ゴーストは頭を天井にかすめながら正立して漂います。

### 検証

`rambit validate` と `zig build test` は次の点を確認します。マニフェストの構文（JSON エラーは行と列付き）、必須フィールドと未知のフィールド、値の範囲、フレームの寸法（壁のフレームは `height` × `width`）、パレットの記号、存在しないフレームファイル、フレーム名、アニメーションが揃っていない・`bottom` を含まない・壁なしで天井を含む `edges`、ディレクトリ名と一致しない、またはコマンドやほかの rambler と衝突する id、ファイルサイズの上限です。どのアニメーションにも使われていないスプライトファイルは警告になります。どの端でも使われない壁や天井のアニメーション、`run` アニメーションのない `motion.run_speed`、`jump` アニメーションのない `motion.jump_height` も同様です。

CI はすべてのプルリクエストと `main` へのすべてのプッシュで `zig build validate` と `zig build test` を実行するので、これらの問題はマージ前にプルリクエスト上でわかります。CI はまた `install.sh` とリリース用スクリプトの lint とテストを行い、リリース用のバイナリをクロスビルドします。別のワークフローが、バージョンタグから署名済みのリリースを作成します。

## 仕組み

- **描画。** rambler は論理ピクセルのフレームバッファに描かれます。ターミナルの各セルは、ANSI の前景色と背景色を使った `▀` と `▄` で 2 ピクセルを表示します。前のフレームから変化したセルだけが書き出されます。
- **動きとアニメーションは別々。** 動きのロジックがどこへ行くか、また歩く、走る、跳ぶ、休む、眠るのどれをするかを決め、rambler はフレームを提供します。動きはシード付きの乱数生成器をもとに 30 Hz の固定ステップで進むので、実行を再現できます。
- **端を一周する 1 本の線。** rambler が歩く端は、位置を並べた 1 本の線に展開されるので、壁を登るのはその線を先へ進むだけのことです。各フレームは、その位置がある端に合わせて配置され、進む方向を向くように反転されます。
- **シェルモード。** `rambit shell` はプログラムを擬似端末上で実行し、その出力を独自のターミナルエミュレーター（`src/vt/`）に渡し、エミュレーターのセルに rambler のピクセルを重ねて、変化したセルを書き出します。rambler はカーソル周辺の行には入りません。[シェルモードの仕組み](#シェルモードの仕組み)を参照してください。
- **ターミナルの扱い。** 実行中は raw 入力、代替スクリーン、カーソル非表示、行の折り返しなしになります。終了時には、`SIGINT`、`SIGTERM`、`SIGHUP` やパニックの場合も含めてターミナルが復元されます。`rambit shell` を終了すると、プログラムから反映されたキーボードのモードもリセットされます。リサイズは `SIGWINCH` で検出します。
- **単一バイナリ。** `build.zig` が `ramblers/` を走査し、すべてのマニフェストとスプライトを `@embedFile` で埋め込むモジュールを生成します。

```text
install.sh               the installer, for curl | sh
src/
├── main.zig             CLI: play, shell, list, preview, validate
├── play.zig             the animation loop
├── shell.zig            the shell loop: pty, emulator, keys and rambler
├── Actor.zig            movement: walking, climbing, running, jumping, resting, sleeping
├── Track.zig            the edges as one line, and where frames go
├── Rambler.zig          manifest parsing and validation
├── sprite.zig           sprite file parsing
├── Source.zig           embedded files or a directory on disk
├── Diagnostics.zig      problems collected by the validator
├── Canvas.zig           the logical pixel framebuffer
├── Screen.zig           pixels to cells, and cells to escape sequences
├── compose.zig          a rambler's pixels laid over the emulator's cells
├── Display.zig          changed emulator cells to escape sequences
├── Pty.zig              a pseudo-terminal with the child process on it
├── Prefix.zig           the Ctrl-] keys, filtered out of the input
├── poll.zig             waiting on the keyboard and the pty
├── Terminal.zig         raw mode, alternate screen, signals, terminal size
├── color.zig            colors, palettes, 256-color fallback
└── vt/                  the terminal emulator
    ├── vt.zig           the package
    ├── Parser.zig       escape sequences and UTF-8, byte by byte
    ├── Emulator.zig     the program's screens, cursor, modes and replies
    ├── Grid.zig         one screen of cells and its editing operations
    ├── width.zig        how many cells a character takes up
    └── width_table.zig  generated by tools/width_table.py
tools/
├── build-release.sh     the four release binaries and their SHA256SUMS
├── release-key.sh       the release signing key: generate, embed, check
├── test-install.sh      install.sh against fake signed releases
└── width_table.py       the width table, from Python's unicodedata
```

## 未対応

- `rambit shell` でのスクロールバック。
- `rambit shell` でのマウスレポート、ウィンドウタイトル、ハイパーリンク（OSC）。
- 結合文字と絵文字シーケンス。
- 複数の rambler の同時表示。
- 設定可能なプレフィックスキー。

## ライセンス

[MIT](LICENSE)、© 2026 shutx。
