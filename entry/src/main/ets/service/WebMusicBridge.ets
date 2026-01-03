import { webview } from '@kit.ArkWeb';
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { AVSessionService, MediaInfo, PlaybackInfo, AVSessionCallback } from './AVSessionService';

// 从网页端接收的媒体信息接口
interface WebMediaInfo {
  id: string;
  name: string;
  artist: string;
  album?: string;
  duration?: number;
  picUrl?: string;
  isFavorite?: boolean;
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
}

/**
 * Web 与 AVSession 桥接类
 * 负责在 ArkWeb 和 AVSession 之间建立双向通信
 */
export class WebMusicBridge {
  private controller: webview.WebviewController;
  private avSessionService: AVSessionService;
  private isInjected: boolean = false;
  private currentMediaId: string = '';

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
    this.avSessionService = AVSessionService.getInstance();
    this.setupAVSessionCallbacks();
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

    const jsCode = `
      (function() {
        if (window.__avSessionInjected) return;
        window.__avSessionInjected = true;

        console.log('[AVSession] Injecting music monitor for NetEase Cloud Music...');

        // 状态缓存
        const state = {
          initialized: false,
          isPlaying: false,
          isFavorite: false,
          loopMode: 'list',
          songId: '',
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
          lastHowlCheck: 0
        };

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
                  const authorLink = authorEl.querySelector('a');
                  artist = authorLink?.textContent?.trim() || authorEl.textContent?.trim() || '';
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
              const artistSelectors = ['.author a', '[class*="artist"] a', '[class*="singer"] a'];
              for (const sel of artistSelectors) {
                const el = document.querySelector(sel);
                if (el) {
                  artist = el.textContent?.trim() || '';
                  if (artist) break;
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

        function monitor(forceNotify = false) {
          const isPlaying = checkPlayState();
          const isFavorite = checkFavoriteState();
          const loopMode = checkLoopMode();
          const { currentTime, duration } = getProgressInfo();
          const { songName, artist, coverUrl } = getSongInfo();
          const songId = songName + '-' + artist;

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

          // 状态变化或强制通知时上报
          if (stateChanged || forceNotify) {
            notifyPlayStateChange(state.isPlaying, currentTime, duration, state.isFavorite, state.loopMode);
          }

          // 歌曲变化时上报
          if (songName && (songId !== state.songId || forceNotify)) {
            state.songId = songId;
            state.songName = songName;
            state.artist = artist;
            state.coverUrl = coverUrl;
            state.duration = duration;
            notifySongChange({
              id: songId,
              name: songName,
              artist: artist,
              picUrl: coverUrl,
              duration: duration,
              isFavorite: state.isFavorite
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

    console.info(`[WebMusicBridge] Song: ${info.name} - ${info.artist}, duration: ${info.duration}s`);
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
      }
    };
    return bridgeObject;
  }

  // 获取桥接对象的方法名列表，用于 javaScriptProxy
  public getBridgeMethodList(): string[] {
    return ['onPlayStateChange', 'onTimeUpdate', 'onSongInfoChange'];
  }
}

