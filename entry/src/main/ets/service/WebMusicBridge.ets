import { webview } from '@kit.ArkWeb';
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { AVSessionService, MediaInfo, PlaybackInfo, AVSessionCallback } from './AVSessionService';
import { PreferencesUtil } from '../utiles/PreferencesHelper';
import { LyricService } from './LyricService';
import { QualityService, QualityUrlData } from './QualityService';

// 持久化存储的 key
const LAST_SONG_ID_KEY = 'lastSongId';
const QUALITY_REPLACE_ENABLED_KEY = 'qualityReplaceEnabled';
const QUALITY_REPLACE_LEVEL_KEY = 'qualityReplaceLevel';

// 从网页端接收的媒体信息接口
interface WebMediaInfo {
  id: string;
  name: string;
  artist: string;
  album?: string;
  duration?: number;
  picUrl?: string;
  isFavorite?: boolean;
  songId?: number; // 网易云音乐歌曲 ID（通过网络请求拦截获取）
}

// 从网页端接收的播放状态接口
interface WebPlaybackState {
  isPlaying: boolean;
  currentTime: number;
  duration: number;
  isFavorite?: boolean;
  loopMode?: string;
}

// 桥接对象接口，用于 Web 组件的 javaScriptProxy
export interface AVSessionBridgeObject {
  onPlayStateChange: (isPlaying: boolean, currentTime: number, duration: number,
    isFavorite?: boolean, loopMode?: string) => void;
  onTimeUpdate: (currentTime: number, duration: number) => void;
  onSongInfoChange: (info: WebMediaInfo) => void;
  onQualitySettingsChange: (enabled: boolean, level: string) => void;
  fetchQualityUrl: (songId: number, level: string) => Promise<string>;
}

/**
 * Web 与 AVSession 桥接类
 * 负责在 ArkWeb 和 AVSession 之间建立双向通信
 */
interface QualitySettings {
  enabled: boolean;
  level: string;
}

export class WebMusicBridge {
  private controller: webview.WebviewController;
  private avSessionService: AVSessionService;
  private lyricService: LyricService;
  private qualityService: QualityService;
  private isInjected: boolean = false;
  private currentMediaId: string = '';
  private currentSongId: number = 0; // 网易云音乐歌曲 ID（通过网络请求拦截获取）
  // 音质替换设置
  private qualityReplaceEnabled: boolean = false;
  private qualityReplaceLevel: string = 'exhigh';

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
    this.avSessionService = AVSessionService.getInstance();
    this.lyricService = LyricService.getInstance();
    this.qualityService = QualityService.getInstance();
    this.setupAVSessionCallbacks();
    this.loadLastSongId();
    this.loadQualitySettings();
  }

  // 从持久化存储加载上次保存的歌曲 ID
  private loadLastSongId(): void {
    try {
      if (PreferencesUtil.isInitialized()) {
        const lastSongId = PreferencesUtil.get<number>(LAST_SONG_ID_KEY, 0);
        if (lastSongId && lastSongId > 0) {
          this.currentSongId = lastSongId;
          console.info(`[WebMusicBridge] Loaded last song ID from storage: ${lastSongId}`);
        }
      }
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to load last song ID: ${err}`);
    }
  }

  // 保存歌曲 ID 到持久化存储
  private saveSongId(songId: number): void {
    if (songId <= 0) return;
    try {
      if (PreferencesUtil.isInitialized()) {
        PreferencesUtil.put(LAST_SONG_ID_KEY, songId);
        console.info(`[WebMusicBridge] Saved song ID to storage: ${songId}`);
      }
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to save song ID: ${err}`);
    }
  }

  // 加载音质替换设置
  private loadQualitySettings(): void {
    try {
      if (PreferencesUtil.isInitialized()) {
        this.qualityReplaceEnabled = PreferencesUtil.get<boolean>(QUALITY_REPLACE_ENABLED_KEY, false);
        this.qualityReplaceLevel = PreferencesUtil.get<string>(QUALITY_REPLACE_LEVEL_KEY, 'exhigh');
        console.info(`[WebMusicBridge] Loaded quality settings: enabled=${this.qualityReplaceEnabled}, level=${this.qualityReplaceLevel}`);
      }
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to load quality settings: ${err}`);
    }
  }

  // 保存音质替换设置
  public saveQualitySettings(enabled: boolean, level: string): void {
    try {
      if (PreferencesUtil.isInitialized()) {
        this.qualityReplaceEnabled = enabled;
        this.qualityReplaceLevel = level;
        PreferencesUtil.put(QUALITY_REPLACE_ENABLED_KEY, enabled);
        PreferencesUtil.put(QUALITY_REPLACE_LEVEL_KEY, level);
        console.info(`[WebMusicBridge] Saved quality settings: enabled=${enabled}, level=${level}`);
      }
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to save quality settings: ${err}`);
    }
  }

  // 获取音质替换设置
  public getQualitySettings(): QualitySettings {
    return {
      enabled: this.qualityReplaceEnabled,
      level: this.qualityReplaceLevel
    };
  }

  // 获取当前歌曲 ID（优先使用拦截到的 ID，否则使用持久化存储的 ID）
  public getCurrentSongId(): number {
    return this.currentSongId;
  }

  // 设置 AVSession 回调，将播控命令转发到网页
  private setupAVSessionCallbacks(): void {
    const callback: AVSessionCallback = {
      onPlay: () => {
        this.executeWebCommand('play');
      },
      onPause: () => {
        this.executeWebCommand('pause');
      },
      onStop: () => {
        this.executeWebCommand('stop');
      },
      onPlayNext: () => {
        this.executeWebCommand('next');
      },
      onPlayPrevious: () => {
        this.executeWebCommand('previous');
      },
      onSeek: (time: number) => {
        this.executeWebCommand('seek', time / 1000); // 转换为秒
      },
      onSetLoopMode: (mode) => {
        this.executeWebCommand('loopMode', mode);
      },
      onToggleFavorite: () => {
        this.executeWebCommand('favorite');
      }
    };
    this.avSessionService.setCallback(callback);
  }

  // 向网页发送播控命令
  private executeWebCommand(command: string, value?: number): void {
    let jsCode: string;
    switch (command) {
      case 'play':
        jsCode = `
          (function() {
            // 网易云音乐：点击播放按钮
            const playBtn = document.getElementById('btn_pc_minibar_play');
            if (playBtn) {
              // 检查当前是否为暂停状态（按钮显示播放图标）
              const classList = playBtn.className || '';
              if (!classList.includes('pause')) {
                playBtn.click();
                console.log('[AVSession] Clicked play button');
              }
            }
          })();
        `;
        break;
      case 'pause':
        jsCode = `
          (function() {
            // 网易云音乐：点击暂停按钮
            const playBtn = document.getElementById('btn_pc_minibar_play');
            if (playBtn) {
              // 检查当前是否为播放状态（按钮显示暂停图标）
              const classList = playBtn.className || '';
              if (classList.includes('pause')) {
                playBtn.click();
                console.log('[AVSession] Clicked pause button');
              }
            }
          })();
        `;
        break;
      case 'stop':
        jsCode = `
          (function() {
            // 网易云音乐：暂停并重置
            const playBtn = document.getElementById('btn_pc_minibar_play');
            if (playBtn) {
              const classList = playBtn.className || '';
              if (classList.includes('pause')) {
                playBtn.click();
              }
            }
          })();
        `;
        break;
      case 'next':
        jsCode = `
          (function() {
            // 网易云音乐：下一首按钮
            const nextBtn = document.querySelector('span[aria-label="next"]') ||
                           document.querySelector('[title="下一首"]');
            if (nextBtn) {
              nextBtn.click();
              console.log('[AVSession] Clicked next button');
            }
          })();
        `;
        break;
      case 'previous':
        jsCode = `
          (function() {
            // 网易云音乐：上一首按钮
            const prevBtn = document.querySelector('span[aria-label="pre"]') ||
                           document.querySelector('[title="上一首"]');
            if (prevBtn) {
              prevBtn.click();
              console.log('[AVSession] Clicked previous button');
            }
          })();
        `;
        break;
      case 'seek':
        jsCode = `
          (function() {
            const targetTime = ${value};
            let seekSuccess = false;
            console.log('[AVSession] ====== SEEK START ======');
            console.log('[AVSession] Target time:', targetTime, 'seconds');

            // 方法0: 使用我们追踪的活跃 Howl 实例（最可靠）
            if (window.__avSessionSeek && typeof window.__avSessionSeek === 'function') {
              seekSuccess = window.__avSessionSeek(targetTime);
              if (seekSuccess) {
                console.log('[AVSession] Seek via tracked Howl SUCCESS');
              }
            }

            // 方法1: 使用 __avSessionGetActiveHowl 获取活跃实例
            if (!seekSuccess && window.__avSessionGetActiveHowl) {
              const activeHowl = window.__avSessionGetActiveHowl();
              if (activeHowl && typeof activeHowl.seek === 'function') {
                try {
                  const beforePos = activeHowl.seek();
                  console.log('[AVSession] Active Howl before seek:', beforePos);
                  activeHowl.seek(targetTime);
                  const afterPos = activeHowl.seek();
                  console.log('[AVSession] Active Howl after seek:', afterPos);
                  if (Math.abs(afterPos - targetTime) < 2) {
                    seekSuccess = true;
                    console.log('[AVSession] Active Howl seek SUCCESS');
                  }
                } catch (e) {
                  console.error('[AVSession] Active Howl seek error:', e);
                }
              }
            }

            // 方法2: 遍历所有 Howl 实例，只对正在播放的进行 seek
            if (!seekSuccess && window.Howler && window.Howler._howls) {
              console.log('[AVSession] Trying all Howls, count:', window.Howler._howls.length);
              for (let i = window.Howler._howls.length - 1; i >= 0; i--) {
                const howl = window.Howler._howls[i];
                if (howl && typeof howl.seek === 'function' && howl.playing && howl.playing()) {
                  try {
                    howl.seek(targetTime);
                    const newPos = howl.seek();
                    console.log('[AVSession] Howl', i, 'seeked to:', newPos);
                    if (Math.abs(newPos - targetTime) < 2) {
                      seekSuccess = true;
                      break;
                    }
                  } catch (e) {
                    console.error('[AVSession] Howl', i, 'seek error:', e);
                  }
                }
              }
            }

            // 方法3: 进度条 slider 模拟（作为备用）
            if (!seekSuccess) {
              const slider = document.querySelector('.slider-default input[type="range"]');
              if (slider) {
                const max = parseFloat(slider.max) || 1;
                console.log('[AVSession] Slider fallback - max:', max, 'target:', targetTime);

                const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value'
                )?.set;

                if (nativeInputValueSetter) {
                  nativeInputValueSetter.call(slider, targetTime);
                } else {
                  slider.value = targetTime.toString();
                }

                const rect = slider.getBoundingClientRect();
                const percent = targetTime / max;
                const clientX = rect.left + rect.width * percent;
                const clientY = rect.top + rect.height / 2;

                slider.dispatchEvent(new MouseEvent('mousedown', {
                  bubbles: true, cancelable: true, clientX, clientY, view: window
                }));
                slider.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                slider.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                slider.dispatchEvent(new MouseEvent('mouseup', {
                  bubbles: true, cancelable: true, clientX, clientY, view: window
                }));

                console.log('[AVSession] Slider events dispatched');
              }
            }

            console.log('[AVSession] ====== SEEK END, success:', seekSuccess, '======');
          })();
        `;
        break;
      case 'favorite':
        jsCode = `
          (function() {
            // 网易云音乐：喜欢按钮
            const likeBtn = document.querySelector('[aria-label="like"]') ||
                           document.querySelector('[title="喜欢"]') ||
                           document.querySelector('[title="取消喜欢"]');
            if (likeBtn) {
              likeBtn.click();
              console.log('[AVSession] Clicked favorite button');
            }
          })();
        `;
        break;
      case 'loopMode':
        jsCode = `
          (function() {
            // 网易云音乐：循环模式按钮
            // 0: 顺序播放, 1: 单曲循环, 2: 列表循环, 3: 随机播放
            const loopBtn = document.querySelector('[aria-label="loop"]') ||
                           document.querySelector('[aria-label="singleloop"]') ||
                           document.querySelector('[aria-label="order"]') ||
                           document.querySelector('[aria-label="shuffle"]') ||
                           document.querySelector('[title="列表循环"]') ||
                           document.querySelector('[title="单曲循环"]') ||
                           document.querySelector('[title="顺序播放"]') ||
                           document.querySelector('[title="随机播放"]');
            if (loopBtn) {
              // 点击切换到下一个模式
              loopBtn.click();
              console.log('[AVSession] Clicked loop mode button');
            }
          })();
        `;
        break;
      default:
        return;
    }

    try {
      this.controller.runJavaScript(jsCode);
      console.info(`[WebMusicBridge] Executed command: ${command}`);
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to execute command: ${command}, error: ${err}`);
    }
  }

  // 注入 JavaScript 代码到网页，用于监听音频事件
  // 针对网易云音乐网页版优化，追踪 Howler.js 实例
  public injectMusicMonitor(): void {
    if (this.isInjected) return;

    // 获取上次保存的歌曲 ID，用于初始化
    const lastSongId = this.currentSongId;
    // 获取音质替换设置
    const qualityEnabled = this.qualityReplaceEnabled;
    const qualityLevel = this.qualityReplaceLevel;

    const jsCode = `
      (function() {
        if (window.__avSessionInjected) return;
        window.__avSessionInjected = true;

        console.log('[AVSession] Injecting music monitor for NetEase Cloud Music...');

        // 从 Native 层传入的上次保存的歌曲 ID
        const LAST_SAVED_SONG_ID = ${lastSongId};
        console.log('[AVSession] Last saved song ID from storage:', LAST_SAVED_SONG_ID);

        // 状态缓存
        const state = {
          initialized: false,
          isPlaying: false,
          isFavorite: false,
          loopMode: 'list',
          songId: '',
          numericSongId: LAST_SAVED_SONG_ID, // 使用上次保存的歌曲 ID 作为初始值
          songName: '',
          artist: '',
          coverUrl: '',
          currentTime: 0,
          duration: 0,
          lastNotifyTime: 0,
          sliderListenerAttached: false,
          // Howler 追踪
          activeHowlId: null,
          howlInstances: new Map(), // id -> { howl, createdAt, lastSeek }
          lastHowlCheck: 0,
          // 网络拦截获取的歌曲 ID
          interceptedSongId: LAST_SAVED_SONG_ID, // 使用上次保存的歌曲 ID 作为初始值
          lastInterceptedSongId: 0,
          // 音质替换设置
          qualityReplaceEnabled: ${qualityEnabled},
          qualityReplaceLevel: '${qualityLevel}',
          // 待替换的高音质 URL
          pendingQualityUrl: null,
          pendingQualitySongId: null,
          // 开发者控制台日志
          consoleLogs: [],
          maxConsoleLogs: 500
        };

        // ========== 开发者控制台 - Console 拦截 ==========
        const originalConsole = {
          log: console.log.bind(console),
          info: console.info.bind(console),
          warn: console.warn.bind(console),
          error: console.error.bind(console)
        };

        function formatLogArgs(args) {
          return Array.from(args).map(arg => {
            if (arg === null) return 'null';
            if (arg === undefined) return 'undefined';
            if (typeof arg === 'object') {
              try {
                return JSON.stringify(arg, null, 2);
              } catch (e) {
                return String(arg);
              }
            }
            return String(arg);
          }).join(' ');
        }

        function addLogEntry(level, args) {
          const entry = {
            timestamp: new Date().toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3 }),
            level: level,
            message: formatLogArgs(args)
          };
          state.consoleLogs.push(entry);
          if (state.consoleLogs.length > state.maxConsoleLogs) {
            state.consoleLogs.shift();
          }
          // 更新控制台 UI
          updateDevConsoleUI(entry);
        }

        console.log = function(...args) {
          addLogEntry('log', args);
          originalConsole.log.apply(console, args);
        };
        console.info = function(...args) {
          addLogEntry('info', args);
          originalConsole.info.apply(console, args);
        };
        console.warn = function(...args) {
          addLogEntry('warn', args);
          originalConsole.warn.apply(console, args);
        };
        console.error = function(...args) {
          addLogEntry('error', args);
          originalConsole.error.apply(console, args);
        };

        // 更新开发者控制台 UI
        function updateDevConsoleUI(entry) {
          const consoleContent = document.getElementById('dev-console-content');
          if (!consoleContent) return;

          const logLine = document.createElement('div');
          logLine.className = 'dev-console-line dev-console-' + entry.level;

          const timestamp = document.createElement('span');
          timestamp.className = 'dev-console-timestamp';
          timestamp.textContent = entry.timestamp;

          const level = document.createElement('span');
          level.className = 'dev-console-level';
          level.textContent = '[' + entry.level.toUpperCase() + ']';

          const message = document.createElement('span');
          message.className = 'dev-console-message';
          message.textContent = entry.message;

          logLine.appendChild(timestamp);
          logLine.appendChild(level);
          logLine.appendChild(message);
          consoleContent.appendChild(logLine);

          // 自动滚动到底部
          consoleContent.scrollTop = consoleContent.scrollHeight;
        }

        // ========== 网络请求拦截 ==========
        // 通过拦截 weapi/song/enhance/player/url/v1 接口获取真实歌曲 ID
        const TARGET_PATH = 'weapi/song/enhance/player/url/v1';

        // 异步获取高音质 URL
        async function fetchQualityUrlFromNative(songId, level) {
          if (!window.__avSessionBridge || !window.__avSessionBridge.fetchQualityUrl) {
            console.warn('[AVSession] fetchQualityUrl not available');
            return null;
          }
          try {
            const url = await window.__avSessionBridge.fetchQualityUrl(songId, level);
            return url || null;
          } catch (e) {
            console.error('[AVSession] Failed to fetch quality URL:', e);
            return null;
          }
        }

        // 拦截 XMLHttpRequest
        const originalXhrOpen = XMLHttpRequest.prototype.open;
        const originalXhrSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url, ...args) {
          this._avSessionUrl = url;
          this._avSessionMethod = method;
          return originalXhrOpen.apply(this, [method, url, ...args]);
        };

        XMLHttpRequest.prototype.send = function(body) {
          const xhr = this;
          const isTargetRequest = xhr._avSessionUrl && xhr._avSessionUrl.indexOf(TARGET_PATH) > -1;

          if (isTargetRequest && state.qualityReplaceEnabled) {
            // 音质替换模式：拦截响应并替换 URL
            xhr.addEventListener('readystatechange', async function() {
              if (xhr.readyState === 4 && xhr.status === 200) {
                try {
                  const res = JSON.parse(xhr.responseText);
                  if (res.data && res.data[0] && res.data[0].id) {
                    const songId = res.data[0].id;
                    console.log('[AVSession] XHR Intercepted song ID:', songId);
                    state.interceptedSongId = songId;
                    notifySongIdChange(songId);

                    // 获取高音质 URL
                    const qualityUrl = await fetchQualityUrlFromNative(songId, state.qualityReplaceLevel);
                    if (qualityUrl) {
                      console.log('[AVSession] Replacing URL with quality:', state.qualityReplaceLevel);
                      // 由于无法直接修改 responseText，我们通过修改 Howler 的 src 来实现
                      state.pendingQualityUrl = qualityUrl;
                      state.pendingQualitySongId = songId;
                    }
                  }
                } catch (e) {
                  console.error('[AVSession] XHR parse error:', e);
                }
              }
            });
          } else {
            // 普通模式：只记录歌曲 ID
            xhr.addEventListener('load', function() {
              if (isTargetRequest) {
                try {
                  const res = JSON.parse(xhr.responseText);
                  if (res.data && res.data[0] && res.data[0].id) {
                    const songId = res.data[0].id;
                    console.log('[AVSession] XHR Intercepted song ID:', songId);
                    state.interceptedSongId = songId;
                    notifySongIdChange(songId);
                  }
                } catch (e) {
                  console.error('[AVSession] XHR parse error:', e);
                }
              }
            });
          }
          return originalXhrSend.apply(this, [body]);
        };

        // 拦截 Fetch
        const originalFetch = window.fetch;
        window.fetch = async function(...args) {
          let url = '';
          if (typeof args[0] === 'string') url = args[0];
          else if (args[0] instanceof Request) url = args[0].url;

          const isTargetRequest = url && url.indexOf(TARGET_PATH) > -1;

          if (isTargetRequest && state.qualityReplaceEnabled) {
            // 音质替换模式
            const response = await originalFetch(...args);
            const clone = response.clone();

            try {
              const data = await clone.json();
              if (data.data && data.data[0] && data.data[0].id) {
                const songId = data.data[0].id;
                console.log('[AVSession] Fetch Intercepted song ID:', songId);
                state.interceptedSongId = songId;
                notifySongIdChange(songId);

                // 获取高音质 URL
                const qualityUrl = await fetchQualityUrlFromNative(songId, state.qualityReplaceLevel);
                if (qualityUrl) {
                  console.log('[AVSession] Replacing Fetch URL with quality:', state.qualityReplaceLevel);
                  // 修改响应数据
                  data.data[0].url = qualityUrl;
                  // 创建新的响应
                  const modifiedResponse = new Response(JSON.stringify(data), {
                    status: response.status,
                    statusText: response.statusText,
                    headers: response.headers
                  });
                  return modifiedResponse;
                }
              }
            } catch (e) {
              console.error('[AVSession] Fetch parse error:', e);
            }

            return response;
          } else {
            // 普通模式
            const response = await originalFetch(...args);

            if (isTargetRequest) {
              const clone = response.clone();
              clone.json().then(data => {
                if (data.data && data.data[0] && data.data[0].id) {
                  const songId = data.data[0].id;
                  console.log('[AVSession] Fetch Intercepted song ID:', songId);
                  state.interceptedSongId = songId;
                  notifySongIdChange(songId);
                }
              }).catch(err => console.error('[AVSession] Fetch parse error:', err));
            }
            return response;
          }
        };

        // 拦截 Howler.js 的音频加载，替换为高音质 URL
        function interceptHowlerSrc() {
          if (!window.Howl) return;

          const OriginalHowl = window.Howl;
          window.Howl = function(options) {
            // 检查是否有待替换的高音质 URL
            if (state.qualityReplaceEnabled && state.pendingQualityUrl && options.src) {
              console.log('[AVSession] Intercepting Howl src, replacing with quality URL');
              if (Array.isArray(options.src)) {
                options.src = [state.pendingQualityUrl];
              } else {
                options.src = state.pendingQualityUrl;
              }
              state.pendingQualityUrl = null;
              state.pendingQualitySongId = null;
            }
            return new OriginalHowl(options);
          };
          // 复制原型和静态属性
          window.Howl.prototype = OriginalHowl.prototype;
          Object.keys(OriginalHowl).forEach(key => {
            window.Howl[key] = OriginalHowl[key];
          });
        }

        // 延迟执行 Howler 拦截，确保 Howler 已加载
        setTimeout(interceptHowlerSrc, 1000);

        console.log('[AVSession] Network interceptor installed for:', TARGET_PATH);

        // 通知歌曲 ID 变化（当拦截到新的歌曲 ID 时调用）
        function notifySongIdChange(songId) {
          if (!songId || songId <= 0) {
            console.warn('[AVSession] Invalid song ID received:', songId);
            return;
          }

          if (songId === state.lastInterceptedSongId) {
            console.log('[AVSession] Same song ID, skipping:', songId);
            return;
          }

          console.log('[AVSession] New song ID detected:', songId, '(previous:', state.lastInterceptedSongId, ')');
          state.lastInterceptedSongId = songId;
          state.numericSongId = songId;

          // 延迟获取歌曲信息，确保 UI 和 Howler 已更新
          let retryCount = 0;
          const maxRetries = 5;
          const retryInterval = 200;

          function tryNotify() {
            retryCount++;
            const { songName, artist, coverUrl } = getSongInfo();
            const { duration } = getProgressInfo();

            console.log('[AVSession] Try notify #' + retryCount + ':', songName, '-', artist, 'duration:', duration, 'songId:', songId);

            // 验证数据有效性
            if (!songName) {
              if (retryCount < maxRetries) {
                console.log('[AVSession] Song name not ready, retrying...');
                setTimeout(tryNotify, retryInterval);
                return;
              }
              console.warn('[AVSession] Failed to get song name after', maxRetries, 'retries');
              return;
            }

            // 检查 duration 是否有效（大于 0 且合理）
            if (duration <= 0 || duration > 3600) {
              if (retryCount < maxRetries) {
                console.log('[AVSession] Duration not ready:', duration, ', retrying...');
                setTimeout(tryNotify, retryInterval);
                return;
              }
              console.warn('[AVSession] Using potentially invalid duration:', duration);
            }

            const info = {
              id: songName + '-' + artist,
              name: songName,
              artist: artist,
              picUrl: coverUrl,
              duration: duration,
              isFavorite: state.isFavorite,
              songId: songId
            };

            // 更新 state 中的歌曲信息
            state.songId = info.id;
            state.songName = songName;
            state.artist = artist;
            state.coverUrl = coverUrl;
            state.duration = duration;

            console.log('[AVSession] Notifying song change - ID:', songId, 'Name:', songName, 'Duration:', duration);
            notifySongChange(info);
          }

          // 首次延迟 300ms 后开始尝试
          setTimeout(tryNotify, 300);
        }

        // ========== 设置页面 UI 注入 ==========

        // 音质等级映射
        const QUALITY_LEVELS = [
          { value: 'standard', label: '标准' },
          { value: 'higher', label: '较高' },
          { value: 'exhigh', label: '极高' },
          { value: 'lossless', label: '无损' },
          { value: 'hires', label: 'Hi-Res' }
        ];

        // 注入设置页面 UI
        function injectSettingsUI() {
          const playSection = document.getElementById('play');
          if (!playSection) return false;

          // 检查是否已经注入
          if (document.getElementById('quality-replace-setting')) return true;

          console.log('[AVSession] Injecting quality replace settings UI...');

          // 找到 play section 内的 .play 容器
          const playContainer = playSection.querySelector('.play');
          if (!playContainer) return false;

          // 创建设置项，使用与原有设置一致的结构
          const settingSection = document.createElement('section');
          settingSection.id = 'quality-replace-setting';
          settingSection.className = 'item list';

          // 创建标题，使用与原有 h4 一致的结构
          const title = document.createElement('h4');
          title.textContent = '音质替换';

          // 创建 checkbox 容器，模仿原有样式
          const checkboxWrapper = document.createElement('span');
          checkboxWrapper.className = 'list-item';

          const checkboxLabel = document.createElement('span');
          checkboxLabel.className = 'cmd-checkbox ' + (state.qualityReplaceEnabled ? 'cmd-checkbox-checked' : 'cmd-checkbox-unChecked') + ' cmd-checkbox-cardType_unDisabled CheckboxWrapper_c1o7uw4l';
          checkboxLabel.style.cursor = 'pointer';

          const checkboxInner = document.createElement('span');
          checkboxInner.className = 'cmd-checkbox-inner' + (state.qualityReplaceEnabled ? ' cmd-checkbox-inner-checked' : '');

          const checkboxInput = document.createElement('input');
          checkboxInput.type = 'checkbox';
          checkboxInput.id = 'quality-replace-checkbox';
          checkboxInput.className = 'cmd-checkbox-input';
          checkboxInput.checked = state.qualityReplaceEnabled;
          checkboxInput.setAttribute('aria-checked', state.qualityReplaceEnabled ? 'true' : 'false');
          checkboxInput.setAttribute('aria-label', '启用强制音质替换');
          checkboxInput.setAttribute('aria-labelledby', 'addon-quality-replace');

          const checkboxDisplay = document.createElement('span');
          checkboxDisplay.className = 'cmd-checkbox-inner-display';
          if (state.qualityReplaceEnabled) {
            checkboxDisplay.innerHTML = '<span role="img" aria-label="checkbox_tick" class="cmd-icon cmd-icon-default cmd-icon-checkbox_tick IconStyle_i7u766h"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" focusable="false" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M17.4111 7.30848C18.0692 7.81171 18.1947 8.75312 17.6915 9.41119L11.1915 17.9112C10.909 18.2806 10.4711 18.4981 10.0061 18.5C9.54105 18.5019 9.10143 18.288 8.81592 17.9209L5.31592 13.4209C4.80731 12.767 4.92512 11.8246 5.57904 11.316C6.23296 10.8074 7.17537 10.9252 7.68398 11.5791L9.98988 14.5438L15.3084 7.58884C15.8116 6.93077 16.7531 6.80525 17.4111 7.30848Z" fill="currentColor"></path></svg></span>';
          }

          checkboxInner.appendChild(checkboxInput);
          checkboxInner.appendChild(checkboxDisplay);

          const checkboxContent = document.createElement('div');
          checkboxContent.className = 'cmd-checkbox-content';

          const checkboxAddon = document.createElement('span');
          checkboxAddon.className = 'cmd-checkbox-addon';
          checkboxAddon.id = 'addon-quality-replace';

          const checkboxText = document.createElement('div');
          checkboxText.className = 'text';
          checkboxText.textContent = '启用强制音质替换';

          checkboxAddon.appendChild(checkboxText);
          checkboxContent.appendChild(checkboxAddon);
          checkboxLabel.appendChild(checkboxInner);
          checkboxLabel.appendChild(checkboxContent);
          checkboxWrapper.appendChild(checkboxLabel);

          // 创建音质选择容器，每个音质选项作为单独的 list-item
          const radioContainer = document.createElement('div');
          radioContainer.id = 'quality-level-radios';
          radioContainer.style.marginTop = '12px';
          // 根据 checkbox 初始状态设置显示/隐藏
          radioContainer.style.display = state.qualityReplaceEnabled ? 'block' : 'none';

          // 使用 radio 按钮组，每个选项使用与原有一致的结构
          QUALITY_LEVELS.forEach((level, index) => {
            const listItem = document.createElement('span');
            listItem.className = 'list-item';
            listItem.style.marginBottom = '8px';
            listItem.style.display = 'block';

            const radioLabel = document.createElement('label');
            radioLabel.className = 'cmd-radio' + (level.value === state.qualityReplaceLevel ? ' cmd-radio-checked' : '') + ' RadioWrapper_rg5xp5q';

            const radioInner = document.createElement('span');
            radioInner.className = 'cmd-radio-inner' + (level.value === state.qualityReplaceLevel ? ' cmd-radio-inner-checked' : '');

            const radioInput = document.createElement('input');
            radioInput.type = 'radio';
            radioInput.name = 'quality-level';
            radioInput.value = level.value;
            radioInput.checked = level.value === state.qualityReplaceLevel;
            radioInput.setAttribute('aria-describedby', '');
            radioInput.setAttribute('aria-labelledby', 'addon-quality-' + level.value);

            const radioDisplay = document.createElement('span');
            radioDisplay.className = 'cmd-radio-inner-display';
            if (level.value === state.qualityReplaceLevel) {
              radioDisplay.innerHTML = '<span role="img" aria-label="radio" class="cmd-icon cmd-icon-default cmd-icon-radio IconStyle_i7u766h"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" focusable="false" aria-hidden="true"><circle cx="12" cy="12" r="5" fill="currentColor"></circle></svg></span>';
            }

            radioInner.appendChild(radioInput);
            radioInner.appendChild(radioDisplay);

            const radioContent = document.createElement('div');
            radioContent.className = 'cmd-radio-content';

            const radioAddon = document.createElement('span');
            radioAddon.className = 'cmd-radio-addon';
            radioAddon.id = 'addon-quality-' + level.value;

            const radioText = document.createElement('span');
            radioText.className = 'text';
            radioText.textContent = level.label;

            radioAddon.appendChild(radioText);
            radioContent.appendChild(radioAddon);
            radioLabel.appendChild(radioInner);
            radioLabel.appendChild(radioContent);
            listItem.appendChild(radioLabel);

            // 事件监听
            radioInput.addEventListener('change', function() {
              if (this.checked) {
                state.qualityReplaceLevel = this.value;
                saveQualitySettings();
                console.log('[AVSession] Quality replace level:', this.value);
                // 更新所有 radio 的样式
                radioContainer.querySelectorAll('.cmd-radio').forEach(r => {
                  const input = r.querySelector('input');
                  const inner = r.querySelector('.cmd-radio-inner');
                  const display = r.querySelector('.cmd-radio-inner-display');
                  if (input.checked) {
                    r.classList.add('cmd-radio-checked');
                    inner.classList.add('cmd-radio-inner-checked');
                    display.innerHTML = '<span role="img" aria-label="radio" class="cmd-icon cmd-icon-default cmd-icon-radio IconStyle_i7u766h"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" focusable="false" aria-hidden="true"><circle cx="12" cy="12" r="5" fill="currentColor"></circle></svg></span>';
                  } else {
                    r.classList.remove('cmd-radio-checked');
                    inner.classList.remove('cmd-radio-inner-checked');
                    display.innerHTML = '';
                  }
                });
              }
            });

            radioContainer.appendChild(listItem);
          });

          settingSection.appendChild(title);
          settingSection.appendChild(checkboxWrapper);
          settingSection.appendChild(radioContainer);

          // 插入到 play 容器的末尾
          playContainer.appendChild(settingSection);

          // 更新 checkbox 样式和状态的函数
          function updateCheckboxState(checked) {
            state.qualityReplaceEnabled = checked;
            checkboxInput.checked = checked;
            saveQualitySettings();
            console.log('[AVSession] Quality replace enabled:', checked);

            // 更新样式
            if (checked) {
              checkboxLabel.classList.remove('cmd-checkbox-unChecked');
              checkboxLabel.classList.add('cmd-checkbox-checked');
              checkboxInner.classList.add('cmd-checkbox-inner-checked');
              checkboxDisplay.innerHTML = '<span role="img" aria-label="checkbox_tick" class="cmd-icon cmd-icon-default cmd-icon-checkbox_tick IconStyle_i7u766h"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" focusable="false" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M17.4111 7.30848C18.0692 7.81171 18.1947 8.75312 17.6915 9.41119L11.1915 17.9112C10.909 18.2806 10.4711 18.4981 10.0061 18.5C9.54105 18.5019 9.10143 18.288 8.81592 17.9209L5.31592 13.4209C4.80731 12.767 4.92512 11.8246 5.57904 11.316C6.23296 10.8074 7.17537 10.9252 7.68398 11.5791L9.98988 14.5438L15.3084 7.58884C15.8116 6.93077 16.7531 6.80525 17.4111 7.30848Z" fill="currentColor"></path></svg></span>';
              radioContainer.style.display = 'block';
            } else {
              checkboxLabel.classList.add('cmd-checkbox-unChecked');
              checkboxLabel.classList.remove('cmd-checkbox-checked');
              checkboxInner.classList.remove('cmd-checkbox-inner-checked');
              checkboxDisplay.innerHTML = '';
              radioContainer.style.display = 'none';
            }
            checkboxInput.setAttribute('aria-checked', checked ? 'true' : 'false');
          }

          // 在整个 checkboxLabel 上添加点击事件
          checkboxLabel.addEventListener('click', function(e) {
            // 如果点击的是 input 本身，让 input 的 change 事件处理
            if (e.target === checkboxInput) return;
            // 切换状态
            updateCheckboxState(!checkboxInput.checked);
          });

          // Checkbox input 的 change 事件
          checkboxInput.addEventListener('change', function() {
            updateCheckboxState(this.checked);
          });

          console.log('[AVSession] Quality replace settings UI injected');
          return true;
        }

        // 保存音质设置到 Native
        function saveQualitySettings() {
          if (window.__avSessionBridge && window.__avSessionBridge.onQualitySettingsChange) {
            window.__avSessionBridge.onQualitySettingsChange(state.qualityReplaceEnabled, state.qualityReplaceLevel);
          }
        }

        // ========== 开发者控制台 UI 注入 ==========
        function injectDevConsoleUI() {
          const settingsPage = document.getElementById('page_pc_setting');
          if (!settingsPage) return false;

          // 检查是否已经注入
          if (document.getElementById('dev-console-section')) return true;

          console.log('[AVSession] Injecting developer console UI...');

          // 1. 在侧边导航栏添加"开发者控制台"链接
          const anchorWrapper = settingsPage.querySelector('.cmd-anchor-link-wrapper');
          if (anchorWrapper) {
            const navItem = document.createElement('div');
            navItem.className = 'cmd-anchor-link';
            navItem.setAttribute('role', 'listitem');
            navItem.innerHTML = '<div role="link" tabindex="0" aria-disabled="false" title="开发者控制台" class="cmd-anchor-link-title">开发者控制台</div><div role="list"></div>';

            // 点击事件
            navItem.querySelector('.cmd-anchor-link-title').addEventListener('click', function() {
              // 移除其他 active 状态
              anchorWrapper.querySelectorAll('.cmd-anchor-link-title').forEach(el => {
                el.classList.remove('cmd-anchor-link-title-active');
                el.removeAttribute('aria-details');
              });
              // 添加 active 状态
              this.classList.add('cmd-anchor-link-title-active');
              this.setAttribute('aria-details', 'active');
              // 滚动到控制台区域
              const consoleSection = document.getElementById('dev-console-section');
              if (consoleSection) {
                consoleSection.scrollIntoView({ behavior: 'smooth' });
              }
            });

            anchorWrapper.appendChild(navItem);
          }

          // 2. 创建开发者控制台 section，使用与原有 section 一致的结构
          const consoleSection = document.createElement('section');
          consoleSection.id = 'dev-console-section';
          consoleSection.className = 'Content_c1hxvhpe';
          consoleSection.innerHTML = \`
            <h3>开发者控制台</h3>
            <div class="dev-console-container" style="background: #1e1e1e; border-radius: 8px; overflow: hidden;">
              <div class="dev-console-toolbar" style="display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; background: #2d2d2d; border-bottom: 1px solid #3d3d3d;">
                <span style="color: #d4d4d4; font-size: 12px;">Console Output</span>
                <button id="dev-console-clear" style="padding: 4px 12px; background: #404040; color: #d4d4d4; border: none; border-radius: 4px; cursor: pointer; font-size: 12px;">清空</button>
              </div>
              <div id="dev-console-content" style="height: 400px; overflow-y: auto; padding: 8px 12px; font-family: 'Consolas', 'Monaco', 'Courier New', monospace; font-size: 12px; line-height: 1.6;"></div>
            </div>
            <style>
              .dev-console-line {
                display: flex;
                gap: 8px;
                padding: 2px 0;
                border-bottom: 1px solid #2d2d2d;
              }
              .dev-console-timestamp {
                color: #6a9955;
                flex-shrink: 0;
              }
              .dev-console-level {
                flex-shrink: 0;
                width: 50px;
              }
              .dev-console-message {
                color: #d4d4d4;
                word-break: break-all;
                white-space: pre-wrap;
              }
              .dev-console-log .dev-console-level { color: #808080; }
              .dev-console-info .dev-console-level { color: #4fc1ff; }
              .dev-console-warn .dev-console-level { color: #dcdcaa; }
              .dev-console-warn .dev-console-message { color: #dcdcaa; }
              .dev-console-error .dev-console-level { color: #f14c4c; }
              .dev-console-error .dev-console-message { color: #f14c4c; }
              #dev-console-content::-webkit-scrollbar {
                width: 8px;
              }
              #dev-console-content::-webkit-scrollbar-track {
                background: #1e1e1e;
              }
              #dev-console-content::-webkit-scrollbar-thumb {
                background: #404040;
                border-radius: 4px;
              }
              #dev-console-content::-webkit-scrollbar-thumb:hover {
                background: #505050;
              }
            </style>
          \`;

          // 找到内容区域并添加
          const contentWrapper = settingsPage.querySelector('.Content_c1hxvhpe')?.parentElement;
          if (contentWrapper) {
            contentWrapper.appendChild(consoleSection);
          }

          // 清空按钮事件
          const clearBtn = document.getElementById('dev-console-clear');
          if (clearBtn) {
            clearBtn.addEventListener('click', function() {
              const consoleContent = document.getElementById('dev-console-content');
              if (consoleContent) {
                consoleContent.innerHTML = '';
                state.consoleLogs = [];
              }
            });
          }

          // 渲染已有的日志
          const consoleContent = document.getElementById('dev-console-content');
          if (consoleContent && state.consoleLogs.length > 0) {
            state.consoleLogs.forEach(entry => {
              updateDevConsoleUI(entry);
            });
          }

          console.log('[AVSession] Developer console UI injected');
          return true;
        }

        // 监听设置页面出现
        function observeSettingsPage() {
          const observer = new MutationObserver(function(mutations) {
            const settingsPage = document.getElementById('page_pc_setting');
            if (settingsPage) {
              // 延迟一点确保 DOM 完全加载
              setTimeout(() => {
                injectSettingsUI();
                injectDevConsoleUI();
              }, 100);
            }
          });

          observer.observe(document.body, {
            childList: true,
            subtree: true
          });

          // 初始检查
          if (document.getElementById('page_pc_setting')) {
            setTimeout(() => {
              injectSettingsUI();
              injectDevConsoleUI();
            }, 100);
          }
        }

        // 启动设置页面监听
        observeSettingsPage();

        // ========== Howler.js 追踪 ==========

        // 获取当前活跃的 Howl 实例（正在播放的那个）
        function getActiveHowl() {
          if (!window.Howler || !window.Howler._howls) return null;

          const howls = window.Howler._howls;
          let activeHowl = null;
          let latestTime = 0;

          for (let i = 0; i < howls.length; i++) {
            const howl = howls[i];
            if (!howl) continue;

            // 优先选择正在播放的
            if (howl.playing && howl.playing()) {
              // 如果有多个在播放，选择进度最大的（通常是最新的）
              try {
                const pos = howl.seek();
                if (typeof pos === 'number' && pos >= latestTime) {
                  latestTime = pos;
                  activeHowl = howl;
                  state.activeHowlId = i;
                }
              } catch (e) {}
            }
          }

          // 如果没有正在播放的，返回最后一个有效的
          if (!activeHowl && howls.length > 0) {
            for (let i = howls.length - 1; i >= 0; i--) {
              if (howls[i] && typeof howls[i].seek === 'function') {
                activeHowl = howls[i];
                state.activeHowlId = i;
                break;
              }
            }
          }

          return activeHowl;
        }

        // 从 Howler 获取进度信息
        function getProgressFromHowler() {
          const howl = getActiveHowl();
          if (!howl) return null;

          try {
            const currentTime = howl.seek();
            const duration = howl.duration();

            if (typeof currentTime === 'number' && typeof duration === 'number' && duration > 0) {
              return { currentTime, duration, source: 'howler' };
            }
          } catch (e) {
            console.error('[AVSession] Error getting Howler progress:', e);
          }
          return null;
        }

        // ========== 工具函数 ==========

        function parseTime(timeStr) {
          if (!timeStr) return 0;
          const cleaned = timeStr.replace(/[^0-9:]/g, '');
          const parts = cleaned.split(':');
          if (parts.length === 2) {
            return parseInt(parts[0] || '0') * 60 + parseInt(parts[1] || '0');
          }
          return 0;
        }

        function cleanArtistName(artist) {
          if (!artist) return '';
          return artist.replace(/^歌手[：:]/i, '').trim();
        }

        // ========== 状态获取函数 ==========

        function checkPlayState() {
          // 方法1: 从 Howler 获取播放状态
          const howl = getActiveHowl();
          if (howl && typeof howl.playing === 'function') {
            return howl.playing();
          }

          // 方法2: 从 UI 获取
          try {
            const playBtn = document.getElementById('btn_pc_minibar_play');
            if (!playBtn) return null;
            const classList = playBtn.className || '';
            return classList.includes('pause');
          } catch (e) {
            return null;
          }
        }

        function checkFavoriteState() {
          try {
            const likeBtn = document.querySelector('[aria-label="like"]');
            if (!likeBtn) return null;
            const title = likeBtn.getAttribute('title') || '';
            return title === '取消喜欢';
          } catch (e) {
            return null;
          }
        }

        function checkLoopMode() {
          try {
            const loopBtn = document.querySelector('[aria-label="loop"]') ||
                           document.querySelector('[aria-label="singleloop"]') ||
                           document.querySelector('[aria-label="order"]') ||
                           document.querySelector('[aria-label="shuffle"]');
            if (!loopBtn) return null;
            const title = loopBtn.getAttribute('title') || '';
            const ariaLabel = loopBtn.getAttribute('aria-label') || '';
            if (title === '单曲循环' || ariaLabel === 'singleloop') return 'single';
            if (title === '列表循环' || ariaLabel === 'loop') return 'list';
            if (title === '顺序播放' || ariaLabel === 'order') return 'order';
            if (title === '随机播放' || ariaLabel === 'shuffle') return 'shuffle';
            return 'list';
          } catch (e) {
            return null;
          }
        }

        function getProgressInfo() {
          // 优先从 Howler 获取（最准确）
          const howlerProgress = getProgressFromHowler();
          if (howlerProgress) {
            return howlerProgress;
          }

          // 备用：从 slider 获取
          try {
            let currentTime = 0;
            let duration = 0;
            const slider = document.querySelector('.slider-default input[type="range"]');
            if (slider) {
              currentTime = parseFloat(slider.value) || 0;
              duration = parseFloat(slider.max) || 0;
            }
            if (duration === 0) {
              const timeElements = document.querySelectorAll('[class*="time"]');
              for (const el of timeElements) {
                const text = el.textContent || '';
                if (text.includes('/')) {
                  const parts = text.split('/');
                  currentTime = parseTime(parts[0]);
                  duration = parseTime(parts[1]);
                  break;
                }
              }
            }
            return { currentTime, duration, source: 'slider' };
          } catch (e) {
            return { currentTime: 0, duration: 0, source: 'error' };
          }
        }

        function getSongInfo() {
          try {
            let songName = '';
            let artist = '';
            let coverUrl = '';
            const titleContainer = document.querySelector('.title-container') ||
                                  document.querySelector('[class*="TitleWrapper"]');
            if (titleContainer) {
              const titleDiv = titleContainer.querySelector('.title') ||
                              titleContainer.querySelector('[class*="title"]');
              if (titleDiv) {
                const spans = titleDiv.querySelectorAll(':scope > span');
                if (spans.length > 0) {
                  songName = spans[0].textContent?.trim() || '';
                }
                const authorEl = titleDiv.querySelector('.author') ||
                                titleDiv.querySelector('[class*="author"]');
                if (authorEl) {
                  // 获取所有歌手链接，支持多歌手情况
                  const authorLinks = authorEl.querySelectorAll('a');
                  if (authorLinks.length > 0) {
                    const artists = [];
                    for (let i = 0; i < authorLinks.length; i++) {
                      const name = authorLinks[i].textContent?.trim();
                      if (name) artists.push(name);
                    }
                    artist = artists.join(' / ');
                  } else {
                    artist = authorEl.textContent?.trim() || '';
                  }
                }
              }
            }
            if (!songName) {
              const selectors = ['.marquee-item .title span:first-child', '[class*="song-name"]', '.name a'];
              for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (el) {
                  songName = el.textContent?.trim() || '';
                  if (songName && !songName.includes('-')) break;
                }
              }
            }
            if (!artist) {
              // 尝试获取所有歌手，支持多歌手情况
              const artistContainers = ['.author', '[class*="artist"]', '[class*="singer"]'];
              for (const containerSel of artistContainers) {
                const container = document.querySelector(containerSel);
                if (container) {
                  const links = container.querySelectorAll('a');
                  if (links.length > 0) {
                    const artists = [];
                    for (let i = 0; i < links.length; i++) {
                      const name = links[i].textContent?.trim();
                      if (name) artists.push(name);
                    }
                    artist = artists.join(' / ');
                    if (artist) break;
                  } else {
                    artist = container.textContent?.trim() || '';
                    if (artist) break;
                  }
                }
              }
            }
            artist = cleanArtistName(artist);
            const coverEl = document.querySelector('.miniVinylWrapper img') ||
                           document.querySelector('[class*="cover"] img');
            if (coverEl) {
              coverUrl = coverEl.src || coverEl.getAttribute('data-src') || '';
              if (coverUrl && !coverUrl.startsWith('http')) {
                coverUrl = 'https:' + coverUrl;
              }
            }
            return { songName, artist, coverUrl };
          } catch (e) {
            console.error('[AVSession] Error getting song info:', e);
            return { songName: '', artist: '', coverUrl: '' };
          }
        }

        // ========== 通知函数 ==========

        function notifyPlayStateChange(isPlaying, currentTime, duration, isFavorite, loopMode) {
          // 验证进度数据的合理性
          if (duration > 0 && currentTime > duration) {
            console.warn('[AVSession] Invalid progress: currentTime > duration, correcting...');
            currentTime = Math.min(currentTime, duration);
          }

          try {
            if (window.__avSessionBridge && typeof window.__avSessionBridge.onPlayStateChange === 'function') {
              window.__avSessionBridge.onPlayStateChange(isPlaying, currentTime, duration, isFavorite, loopMode);
              console.log('[AVSession] State:', isPlaying ? 'playing' : 'paused',
                         'pos:', currentTime.toFixed(1), '/', duration.toFixed(1));
            } else {
              console.warn('[AVSession] Bridge not available for play state');
            }
          } catch (e) {
            console.error('[AVSession] Error notifying play state:', e);
          }
        }

        function notifySongChange(info) {
          try {
            if (window.__avSessionBridge && typeof window.__avSessionBridge.onSongInfoChange === 'function') {
              window.__avSessionBridge.onSongInfoChange(info);
              console.log('[AVSession] Song:', info.name, '-', info.artist, 'dur:', info.duration);
            } else {
              console.warn('[AVSession] Bridge not available for song change');
            }
          } catch (e) {
            console.error('[AVSession] Error notifying song change:', e);
          }
        }

        function notifyTimeUpdate(currentTime, duration) {
          // 验证进度数据的合理性
          if (duration > 0 && currentTime > duration) {
            console.warn('[AVSession] Invalid time update: currentTime > duration, skipping...');
            return;
          }

          try {
            if (window.__avSessionBridge && typeof window.__avSessionBridge.onTimeUpdate === 'function') {
              window.__avSessionBridge.onTimeUpdate(currentTime, duration);
            }
          } catch (e) {
            console.error('[AVSession] Error notifying time update:', e);
          }
        }

        // ========== 进度条事件监听 ==========

        function setupSliderListener() {
          if (state.sliderListenerAttached) return;

          const slider = document.querySelector('.slider-default input[type="range"]');
          if (!slider) {
            console.log('[AVSession] Slider not found, will retry...');
            return;
          }

          // 记录上次上报的时间，避免频繁上报
          let lastReportedTime = -1;
          let lastReportTimestamp = 0;
          const MIN_REPORT_INTERVAL = 200; // 最小上报间隔 200ms

          function reportTimeUpdate(currentTime, duration, source) {
            const now = Date.now();
            // 如果时间变化超过 1 秒，或者距离上次上报超过 200ms，则上报
            if (Math.abs(currentTime - lastReportedTime) >= 1 || now - lastReportTimestamp >= MIN_REPORT_INTERVAL) {
              console.log('[AVSession] Slider', source, ':', currentTime.toFixed(1), '/', duration.toFixed(1));
              if (duration > 0 && currentTime <= duration) {
                notifyTimeUpdate(currentTime, duration);
                lastReportedTime = currentTime;
                lastReportTimestamp = now;
              }
            }
          }

          // 监听用户拖动进度条 - input 事件（拖动过程中持续触发）
          slider.addEventListener('input', (e) => {
            const currentTime = parseFloat(e.target.value) || 0;
            const duration = parseFloat(e.target.max) || 0;
            reportTimeUpdate(currentTime, duration, 'input');
          });

          // 监听用户拖动进度条 - change 事件（拖动结束时触发）
          slider.addEventListener('change', (e) => {
            const currentTime = parseFloat(e.target.value) || 0;
            const duration = parseFloat(e.target.max) || 0;
            // change 事件强制上报
            console.log('[AVSession] Slider change:', currentTime.toFixed(1), '/', duration.toFixed(1));
            if (duration > 0 && currentTime <= duration) {
              notifyTimeUpdate(currentTime, duration);
              lastReportedTime = currentTime;
              lastReportTimestamp = Date.now();
            }
          });

          // 监听 mouseup 事件（用户释放鼠标时）
          slider.addEventListener('mouseup', (e) => {
            const currentTime = parseFloat(slider.value) || 0;
            const duration = parseFloat(slider.max) || 0;
            console.log('[AVSession] Slider mouseup:', currentTime.toFixed(1), '/', duration.toFixed(1));
            if (duration > 0 && currentTime <= duration) {
              notifyTimeUpdate(currentTime, duration);
              lastReportedTime = currentTime;
              lastReportTimestamp = Date.now();
            }
          });

          // 监听 touchend 事件（触摸设备）
          slider.addEventListener('touchend', (e) => {
            const currentTime = parseFloat(slider.value) || 0;
            const duration = parseFloat(slider.max) || 0;
            console.log('[AVSession] Slider touchend:', currentTime.toFixed(1), '/', duration.toFixed(1));
            if (duration > 0 && currentTime <= duration) {
              notifyTimeUpdate(currentTime, duration);
              lastReportedTime = currentTime;
              lastReportTimestamp = Date.now();
            }
          });

          // 使用 MutationObserver 监听 value 属性变化（捕获程序化修改）
          const sliderObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
              if (mutation.type === 'attributes' && mutation.attributeName === 'value') {
                const currentTime = parseFloat(slider.value) || 0;
                const duration = parseFloat(slider.max) || 0;
                // 只有当时间变化超过 2 秒时才认为是用户 seek 操作
                if (Math.abs(currentTime - lastReportedTime) >= 2) {
                  console.log('[AVSession] Slider value attr changed:', currentTime.toFixed(1), '/', duration.toFixed(1));
                  if (duration > 0 && currentTime <= duration) {
                    notifyTimeUpdate(currentTime, duration);
                    lastReportedTime = currentTime;
                    lastReportTimestamp = Date.now();
                  }
                }
              }
            }
          });
          sliderObserver.observe(slider, { attributes: true, attributeFilter: ['value'] });

          // 监听进度条容器的点击事件（用户点击进度条跳转）
          const sliderWrapper = slider.closest('.slider-default') || slider.parentElement;
          if (sliderWrapper) {
            sliderWrapper.addEventListener('click', (e) => {
              // 延迟获取值，等待 slider 更新
              setTimeout(() => {
                const currentTime = parseFloat(slider.value) || 0;
                const duration = parseFloat(slider.max) || 0;
                console.log('[AVSession] Slider wrapper click:', currentTime.toFixed(1), '/', duration.toFixed(1));
                if (duration > 0 && currentTime <= duration) {
                  notifyTimeUpdate(currentTime, duration);
                  lastReportedTime = currentTime;
                  lastReportTimestamp = Date.now();
                }
              }, 50);
            });
          }

          state.sliderListenerAttached = true;
          console.log('[AVSession] Slider listener attached with multiple event handlers');
        }

        // ========== 主监控函数 ==========
        // 注意：歌曲信息的上报完全由网络拦截器的 notifySongIdChange 负责
        // monitor() 只负责播放状态、喜欢状态、循环模式的更新

        function monitor(forceNotify = false) {
          const isPlaying = checkPlayState();
          const isFavorite = checkFavoriteState();
          const loopMode = checkLoopMode();
          const { currentTime, duration } = getProgressInfo();
          const { songName, artist, coverUrl } = getSongInfo();

          let stateChanged = false;

          if (isPlaying !== null && isPlaying !== state.isPlaying) {
            state.isPlaying = isPlaying;
            stateChanged = true;
          }
          if (isFavorite !== null && isFavorite !== state.isFavorite) {
            state.isFavorite = isFavorite;
            stateChanged = true;
          }
          if (loopMode !== null && loopMode !== state.loopMode) {
            state.loopMode = loopMode;
            stateChanged = true;
          }

          // 更新 duration（供 notifySongIdChange 使用）
          if (duration > 0) {
            state.duration = duration;
          }

          // 状态变化或强制通知时上报播放状态
          if (stateChanged || forceNotify) {
            notifyPlayStateChange(state.isPlaying, currentTime, duration, state.isFavorite, state.loopMode);
          }

          // 强制通知时（初始化），上报当前歌曲信息
          // 这是唯一在 monitor() 中上报歌曲信息的情况
          if (forceNotify && songName) {
            const songId = songName + '-' + artist;
            const numericId = state.numericSongId || state.interceptedSongId || 0;
            state.songId = songId;
            state.songName = songName;
            state.artist = artist;
            state.coverUrl = coverUrl;
            console.log('[AVSession] Force notify (init) song:', songName, '-', artist, 'numericId:', numericId, 'duration:', duration);
            notifySongChange({
              id: songId,
              name: songName,
              artist: artist,
              picUrl: coverUrl,
              duration: duration,
              isFavorite: state.isFavorite,
              songId: numericId
            });
          }

          // 尝试设置进度条监听
          if (!state.sliderListenerAttached) {
            setupSliderListener();
          }
        }

        // ========== 初始化 ==========

        function setupObservers() {
          const playBtn = document.getElementById('btn_pc_minibar_play');
          if (playBtn) {
            new MutationObserver(() => setTimeout(() => monitor(), 50)).observe(playBtn, {
              attributes: true, attributeFilter: ['class']
            });
            console.log('[AVSession] Play button observer ready');
          }

          const likeBtn = document.querySelector('[aria-label="like"]');
          if (likeBtn) {
            new MutationObserver(() => setTimeout(() => monitor(), 50)).observe(likeBtn, {
              attributes: true, attributeFilter: ['title', 'class']
            });
            console.log('[AVSession] Like button observer ready');
          }

          const loopArea = document.querySelector('[aria-label="loop"]')?.parentElement ||
                          document.querySelector('[aria-label="singleloop"]')?.parentElement;
          if (loopArea) {
            new MutationObserver(() => setTimeout(() => monitor(), 50)).observe(loopArea, {
              childList: true, subtree: true, attributes: true
            });
            console.log('[AVSession] Loop mode observer ready');
          }

          const titleContainer = document.querySelector('.title-container') ||
                                document.querySelector('[class*="TitleWrapper"]');
          if (titleContainer) {
            new MutationObserver(() => setTimeout(() => monitor(), 50)).observe(titleContainer, {
              childList: true, subtree: true, characterData: true
            });
            console.log('[AVSession] Title observer ready');
          }
        }

        function checkMinibarAndInit() {
          // 检查迷你播放器是否存在
          const minibar = document.getElementById('btn_pc_minibar_play') ||
                         document.querySelector('.miniVinylWrapper') ||
                         document.querySelector('.title-container');

          if (minibar) {
            console.log('[AVSession] Minibar detected, initializing immediately...');
            return true;
          }
          return false;
        }

        function init() {
          if (state.initialized) return;
          state.initialized = true;

          console.log('[AVSession] Initializing...');
          console.log('[AVSession] Bridge available:', !!window.__avSessionBridge);

          if (!window.__avSessionBridge) {
            console.error('[AVSession] Bridge not available! Retrying in 500ms...');
            state.initialized = false;
            setTimeout(init, 500);
            return;
          }

          setupObservers();
          setupSliderListener();

          // 立即执行一次完整的状态上报（强制通知）
          monitor(true);

          // 定时轮询作为备用（每2秒）
          setInterval(() => monitor(), 2000);

          console.log('[AVSession] Monitor initialized successfully');
        }

        // 初始化策略：尽早初始化
        function tryInit() {
          if (checkMinibarAndInit()) {
            // 迷你播放器已存在，短暂延迟后初始化
            setTimeout(init, 300);
          } else {
            // 等待页面加载完成
            if (document.readyState === 'complete') {
              setTimeout(init, 500);
            } else {
              window.addEventListener('load', () => setTimeout(init, 500));
            }
          }
        }

        // 立即尝试初始化
        tryInit();

        // 额外的保险：如果1秒后还没初始化，强制初始化
        setTimeout(() => {
          if (!state.initialized) {
            console.log('[AVSession] Force initializing after timeout...');
            init();
          }
        }, 1000);
      })();
    `;

    try {
      this.controller.runJavaScript(jsCode);
      this.isInjected = true;
      console.info('[WebMusicBridge] Music monitor injected successfully');
    } catch (err) {
      console.error(`[WebMusicBridge] Failed to inject music monitor: ${err}`);
    }
  }

  // 将网页循环模式转换为 AVSession 循环模式
  private convertLoopMode(webLoopMode: string): AVSessionManager.LoopMode {
    switch (webLoopMode) {
      case 'single':
        return AVSessionManager.LoopMode.LOOP_MODE_SINGLE;
      case 'list':
        return AVSessionManager.LoopMode.LOOP_MODE_LIST;
      case 'order':
        return AVSessionManager.LoopMode.LOOP_MODE_SEQUENCE;
      case 'shuffle':
        return AVSessionManager.LoopMode.LOOP_MODE_SHUFFLE;
      default:
        return AVSessionManager.LoopMode.LOOP_MODE_LIST;
    }
  }

  // 处理网页端的播放状态变化
  public async handlePlayStateChange(
    isPlaying: boolean,
    currentTime: number,
    duration: number,
    isFavorite?: boolean,
    loopMode?: string
  ): Promise<void> {
    const playbackInfo: PlaybackInfo = {
      state: isPlaying ? 'play' : 'pause',
      position: Math.floor(currentTime * 1000), // 转换为毫秒
      speed: 1.0
    };

    // 添加喜欢状态
    if (isFavorite !== undefined) {
      playbackInfo.isFavorite = isFavorite;
    }

    // 添加循环模式
    if (loopMode) {
      playbackInfo.loopMode = this.convertLoopMode(loopMode);
    }

    await this.avSessionService.setPlaybackState(playbackInfo);

    // 管理后台任务
    if (isPlaying) {
      await this.avSessionService.startBackgroundTask();
    } else {
      await this.avSessionService.stopBackgroundTask();
    }
  }

  // 处理网页端的时间更新
  public async handleTimeUpdate(currentTime: number, duration: number): Promise<void> {
    const playbackInfo: PlaybackInfo = {
      state: 'play',
      position: Math.floor(currentTime * 1000)
    };
    await this.avSessionService.setPlaybackState(playbackInfo);
  }

  // 处理网页端的歌曲信息变化
  public async handleSongInfoChange(info: WebMediaInfo): Promise<void> {
    // 避免重复更新相同的歌曲
    const mediaId = info.id || `${info.name}-${info.artist}`;
    if (mediaId === this.currentMediaId) return;
    this.currentMediaId = mediaId;

    // 记录网易云音乐歌曲 ID（通过网络请求拦截获取）并保存到持久化存储
    if (info.songId && info.songId > 0) {
      this.currentSongId = info.songId;
      this.saveSongId(info.songId); // 保存到持久化存储
      console.info(`[WebMusicBridge] Intercepted song ID: ${info.songId}`);

      // 自动获取歌词
      this.fetchLyricForSong(info.songId);
    }

    const mediaInfo: MediaInfo = {
      assetId: mediaId,
      title: info.name || '未知歌曲',
      artist: info.artist || '未知歌手',
      album: info.album,
      duration: info.duration ? Math.floor(info.duration * 1000) : undefined,
      mediaImage: info.picUrl
    };

    await this.avSessionService.setMediaInfo(mediaInfo);

    // 如果有喜欢状态，也更新播放状态
    if (info.isFavorite !== undefined) {
      const playbackInfo: PlaybackInfo = {
        state: 'play',
        isFavorite: info.isFavorite
      };
      await this.avSessionService.setPlaybackState(playbackInfo);
    }

    console.info(`[WebMusicBridge] Song: ${info.name} - ${info.artist}, duration: ${info.duration}s, songId: ${this.currentSongId}`);
  }

  /**
   * 获取指定歌曲的歌词并更新到 AVSession
   * @param songId 歌曲 ID
   */
  private async fetchLyricForSong(songId: number): Promise<void> {
    try {
      console.info(`[WebMusicBridge] Fetching lyric for song ${songId}`);
      const lyricData = await this.lyricService.fetchLyric(songId);

      console.info(`[WebMusicBridge] Fetched lyric: ${lyricData.rawLyric}`)

      // 将歌词更新到 AVSession metadata
      if (lyricData.hasLyric && lyricData.rawLyric) {
        await this.updateLyricToSession(lyricData.rawLyric);
      }
    } catch (error) {
      console.error(`[WebMusicBridge] Failed to fetch lyric for song ${songId}:`, error);
    }
  }

  /**
   * 更新歌词到 AVSession metadata
   * @param lyric 原始歌词文本（LRC 格式）
   */
  private async updateLyricToSession(lyric: string): Promise<void> {
    try {
      // 直接调用 session 的 setAVMetadata 只更新歌词字段
      const session = this.avSessionService.getSession();
      if (session) {
        const metadata: AVSessionManager.AVMetadata = {
          assetId: this.currentMediaId || '0',
          lyric: lyric
        };
        await session.setAVMetadata(metadata);
        console.info(`[WebMusicBridge] Lyric updated to AVSession, length: ${lyric.length}`);
      }
    } catch (error) {
      console.error('[WebMusicBridge] Failed to update lyric to session:', error);
    }
  }

  /**
   * 获取歌词服务实例
   */
  public getLyricService(): LyricService {
    return this.lyricService;
  }

  /**
   * 获取指定音质的歌曲 URL
   * @param songId 歌曲 ID
   * @param level 音质等级
   * @returns 音质 URL，如果获取失败返回空字符串
   */
  public async fetchQualityUrl(songId: number, level: string): Promise<string> {
    try {
      const result = await this.qualityService.fetchQualityUrl(songId, level);
      if (result && result.url) {
        console.info(`[WebMusicBridge] Got quality URL for song ${songId}: ${result.level}`);
        return result.url;
      }
      return '';
    } catch (error) {
      console.error(`[WebMusicBridge] Failed to fetch quality URL:`, error);
      return '';
    }
  }

  // 获取桥接对象，用于注册到 Web 组件
  public getBridgeObject(): AVSessionBridgeObject {
    const bridgeObject: AVSessionBridgeObject = {
      onPlayStateChange: (isPlaying: boolean, currentTime: number, duration: number,
        isFavorite?: boolean, loopMode?: string): void => {
        this.handlePlayStateChange(isPlaying, currentTime, duration, isFavorite, loopMode);
      },
      onTimeUpdate: (currentTime: number, duration: number): void => {
        this.handleTimeUpdate(currentTime, duration);
      },
      onSongInfoChange: (info: WebMediaInfo): void => {
        this.handleSongInfoChange(info);
      },
      onQualitySettingsChange: (enabled: boolean, level: string): void => {
        this.saveQualitySettings(enabled, level);
      },
      fetchQualityUrl: async (songId: number, level: string): Promise<string> => {
        return await this.fetchQualityUrl(songId, level);
      }
    };
    return bridgeObject;
  }

  // 获取桥接对象的方法名列表，用于 javaScriptProxy
  public getBridgeMethodList(): string[] {
    return ['onPlayStateChange', 'onTimeUpdate', 'onSongInfoChange', 'onQualitySettingsChange', 'fetchQualityUrl'];
  }
}

