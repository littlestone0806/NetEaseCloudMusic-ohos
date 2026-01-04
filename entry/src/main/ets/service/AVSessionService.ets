import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

// 媒体信息接口
export interface MediaInfo {
  assetId: string;
  title: string;
  artist: string;
  album?: string;
  duration?: number;
  mediaImage?: string;
  lyric?: string;
}

// 播放状态接口
export interface PlaybackInfo {
  state: 'play' | 'pause' | 'stop' | 'buffering';
  position?: number;
  speed?: number;
  loopMode?: AVSessionManager.LoopMode;
  isFavorite?: boolean;
}

// 播控命令回调接口
export interface AVSessionCallback {
  onPlay?: () => void;
  onPause?: () => void;
  onStop?: () => void;
  onPlayNext?: () => void;
  onPlayPrevious?: () => void;
  onSeek?: (time: number) => void;
  onSetLoopMode?: (mode: AVSessionManager.LoopMode) => void;
  onToggleFavorite?: (assetId: string) => void;
}

export class AVSessionService {
  private static instance: AVSessionService | null = null;
  private session: AVSessionManager.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private callback: AVSessionCallback = {};
  private isBackgroundTaskRunning: boolean = false;

  private constructor() {}

  public static getInstance(): AVSessionService {
    if (!AVSessionService.instance) {
      AVSessionService.instance = new AVSessionService();
    }
    return AVSessionService.instance;
  }

  // 获取 AVSession 实例
  public getSession(): AVSessionManager.AVSession | null {
    return this.session;
  }

  // 初始化 AVSession
  public async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      // 创建 AVSession
      this.session = await AVSessionManager.createAVSession(context, 'NetEaseCloudMusic', 'audio');
      console.info('[AVSessionService] AVSession created successfully');

      // 设置启动 Ability
      await this.setLaunchAbility();

      // 注册播控命令监听
      this.registerControlCommands();

      // 激活会话
      await this.session.activate();
      console.info('[AVSessionService] AVSession activated successfully');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to initialize AVSession: ${error.code}, ${error.message}`);
    }
  }

  // 设置启动 Ability
  private async setLaunchAbility(): Promise<void> {
    if (!this.session || !this.context) return;

    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      await this.session.setLaunchAbility(agent);
      console.info('[AVSessionService] Launch ability set successfully');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to set launch ability: ${error.code}, ${error.message}`);
    }
  }

  // 注册播控命令监听
  private registerControlCommands(): void {
    if (!this.session) return;

    this.session.on('play', () => {
      console.info('[AVSessionService] Received play command');
      this.callback.onPlay?.();
    });

    this.session.on('pause', () => {
      console.info('[AVSessionService] Received pause command');
      this.callback.onPause?.();
    });

    this.session.on('stop', () => {
      console.info('[AVSessionService] Received stop command');
      this.callback.onStop?.();
    });

    this.session.on('playNext', () => {
      console.info('[AVSessionService] Received playNext command');
      this.callback.onPlayNext?.();
    });

    this.session.on('playPrevious', () => {
      console.info('[AVSessionService] Received playPrevious command');
      this.callback.onPlayPrevious?.();
    });

    this.session.on('seek', (time: number) => {
      console.info(`[AVSessionService] Received seek command: ${time}`);
      this.callback.onSeek?.(time);
    });

    this.session.on('setLoopMode', (mode: AVSessionManager.LoopMode) => {
      console.info(`[AVSessionService] Received setLoopMode command: ${mode}`);
      this.callback.onSetLoopMode?.(mode);
    });

    this.session.on('toggleFavorite', (assetId: string) => {
      console.info(`[AVSessionService] Received toggleFavorite command: ${assetId}`);
      this.callback.onToggleFavorite?.(assetId);
    });
  }

  // 设置播控命令回调
  public setCallback(callback: AVSessionCallback): void {
    this.callback = callback;
  }

  // 更新媒体信息
  public async setMediaInfo(info: MediaInfo): Promise<void> {
    if (!this.session) {
      console.warn('[AVSessionService] Session not available, cannot set media info');
      return;
    }

    try {
      // 构建元数据对象，只包含有效的字段
      const metadata: AVSessionManager.AVMetadata = {
        assetId: info.assetId || '0',
        title: info.title || '未知歌曲',
        artist: info.artist || '未知歌手'
      };

      // 只有当值有效时才添加可选字段
      if (info.album && info.album.length > 0) {
        metadata.album = info.album;
      }
      if (info.duration && info.duration > 0) {
        metadata.duration = info.duration;
      }
      if (info.mediaImage && info.mediaImage.length > 0 && info.mediaImage.startsWith('http')) {
        metadata.mediaImage = info.mediaImage;
      }
      if (info.lyric && info.lyric.length > 0) {
        metadata.lyric = info.lyric;
      }

      console.info(`[AVSessionService] Setting metadata: ${JSON.stringify(metadata)}`);
      await this.session.setAVMetadata(metadata);
      console.info('[AVSessionService] Media info updated successfully');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to set media info: ${error.code}, ${error.message}`);
    }
  }

  // 更新播放状态
  public async setPlaybackState(info: PlaybackInfo): Promise<void> {
    if (!this.session) {
      console.warn('[AVSessionService] Session not available, cannot set playback state');
      return;
    }

    try {
      let state: AVSessionManager.PlaybackState;
      switch (info.state) {
        case 'play':
          state = AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY;
          break;
        case 'pause':
          state = AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE;
          break;
        case 'stop':
          state = AVSessionManager.PlaybackState.PLAYBACK_STATE_STOP;
          break;
        case 'buffering':
          state = AVSessionManager.PlaybackState.PLAYBACK_STATE_BUFFERING;
          break;
        default:
          state = AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE;
      }

      // 构建播放状态对象，只包含必要字段
      const playbackState: AVSessionManager.AVPlaybackState = {
        state: state,
        speed: info.speed ?? 1.0
      };

      // 只有当值有效时才添加可选字段
      if (info.loopMode !== undefined) {
        playbackState.loopMode = info.loopMode;
      }
      if (info.isFavorite !== undefined) {
        playbackState.isFavorite = info.isFavorite;
      }
      if (info.position !== undefined && info.position >= 0) {
        playbackState.position = {
          elapsedTime: info.position,
          updateTime: new Date().getTime()
        };
      }

      console.info(`[AVSessionService] Setting playback state: ${info.state}, position: ${info.position}`);
      await this.session.setAVPlaybackState(playbackState);
      console.info(`[AVSessionService] Playback state updated: ${info.state}`);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to set playback state: ${error.code}, ${error.message}`);
    }
  }

  // 启动后台任务
  public async startBackgroundTask(): Promise<void> {
    if (!this.context || this.isBackgroundTaskRunning) return;

    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);

      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.isBackgroundTaskRunning = true;
      console.info('[AVSessionService] Background task started successfully');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to start background task: ${error.code}, ${error.message}`);
    }
  }

  // 停止后台任务
  public async stopBackgroundTask(): Promise<void> {
    if (!this.context || !this.isBackgroundTaskRunning) return;

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.isBackgroundTaskRunning = false;
      console.info('[AVSessionService] Background task stopped successfully');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to stop background task: ${error.code}, ${error.message}`);
    }
  }

  // 销毁 AVSession
  public async destroy(): Promise<void> {
    try {
      // 停止后台任务
      await this.stopBackgroundTask();

      // 销毁会话
      if (this.session) {
        // 取消所有监听
        this.session.off('play');
        this.session.off('pause');
        this.session.off('stop');
        this.session.off('playNext');
        this.session.off('playPrevious');
        this.session.off('seek');
        this.session.off('setLoopMode');
        this.session.off('toggleFavorite');

        await this.session.destroy();
        this.session = null;
        console.info('[AVSessionService] AVSession destroyed successfully');
      }
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[AVSessionService] Failed to destroy AVSession: ${error.code}, ${error.message}`);
    }
  }

  // 获取会话是否已初始化
  public isInitialized(): boolean {
    return this.session !== null;
  }
}
