/**
 * 网易云音乐歌词服务
 * 负责获取原始 LRC 歌词数据，由系统 AVSession 处理解析和显示
 */
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { NeteaseEncrypt, EncryptedParams } from '../utils/NeteaseEncrypt';

// 网易云音乐 API 基础 URL
const NETEASE_BASE_URL = 'https://music.163.com';
const LYRIC_API_PATH = '/weapi/song/lyric/v1';

/**
 * 歌词数据
 */
export interface LyricData {
  songId: number;           // 歌曲 ID
  hasLyric: boolean;        // 是否有歌词
  rawLyric: string;         // 原始歌词文本（LRC 格式）
}

/**
 * API 响应中的歌词对象
 */
interface LyricObject {
  lyric?: string;
}

/**
 * 网易云音乐歌词 API 响应
 */
interface LyricApiResponse {
  code: number;
  lrc?: LyricObject;
  tlyric?: LyricObject;
  romalrc?: LyricObject;
}

/**
 * 歌词请求参数
 */
interface LyricRequestData {
  id: number;
  cp: boolean;
  tv: number;
  lv: number;
  rv: number;
  kv: number;
  yv: number;
  ytv: number;
  yrv: number;
}

/**
 * 歌词变化回调
 */
export type LyricChangeCallback = (lyricData: LyricData) => void;

/**
 * 歌词服务类
 */
export class LyricService {
  private static instance: LyricService | null = null;
  private lyricCache: Map<number, LyricData> = new Map();
  private currentSongId: number = 0;
  private currentLyric: LyricData | null = null;
  private callbacks: LyricChangeCallback[] = [];

  private constructor() {}

  /**
   * 获取单例实例
   */
  public static getInstance(): LyricService {
    if (!LyricService.instance) {
      LyricService.instance = new LyricService();
    }
    return LyricService.instance;
  }

  /**
   * 注册歌词变化回调
   */
  public onLyricChange(callback: LyricChangeCallback): void {
    this.callbacks.push(callback);
  }

  /**
   * 移除歌词变化回调
   */
  public offLyricChange(callback: LyricChangeCallback): void {
    const index = this.callbacks.indexOf(callback);
    if (index > -1) {
      this.callbacks.splice(index, 1);
    }
  }

  /**
   * 通知所有回调
   */
  private notifyCallbacks(lyricData: LyricData): void {
    for (const callback of this.callbacks) {
      try {
        callback(lyricData);
      } catch (error) {
        console.error('[LyricService] Callback error:', error);
      }
    }
  }

  /**
   * 获取当前歌词数据
   */
  public getCurrentLyric(): LyricData | null {
    return this.currentLyric;
  }

  /**
   * 获取当前歌曲 ID
   */
  public getCurrentSongId(): number {
    return this.currentSongId;
  }

  /**
   * 从 Cookie 字符串中提取 csrf_token
   */
  private extractCsrfToken(cookieStr: string): string {
    if (!cookieStr) return '';
    const cookies = cookieStr.split(';');
    for (const cookie of cookies) {
      const parts = cookie.trim().split('=');
      const name = parts[0];
      const value = parts.length > 1 ? parts[1] : '';
      if (name === '__csrf') {
        return value || '';
      }
    }
    return '';
  }

  /**
   * 获取 Cookie（从 WebCookieManager）
   */
  private async getCookies(): Promise<string> {
    try {
      const cookies = await webview.WebCookieManager.fetchCookie(NETEASE_BASE_URL);
      return cookies || '';
    } catch (error) {
      console.error('[LyricService] Failed to get cookies:', error);
      return '';
    }
  }

  /**
   * 过滤歌词，只保留标准 LRC 格式的行
   * 移除 JSON 格式的元数据行（如作词、作曲信息）
   */
  private filterLyric(rawLyric: string): string {
    if (!rawLyric) return '';

    const lines = rawLyric.split('\n');
    const filteredLines: string[] = [];
    // 标准 LRC 时间标签格式: [mm:ss.xx] 或 [mm:ss.xxx]
    const lrcTimePattern = /^\[(\d{2}):(\d{2})\.(\d{2,3})\]/;

    for (const line of lines) {
      const trimmedLine = line.trim();
      // 跳过空行
      if (!trimmedLine) continue;
      // 跳过 JSON 格式的行（以 { 开头）
      if (trimmedLine.startsWith('{')) continue;
      // 只保留标准 LRC 时间标签格式的行
      if (lrcTimePattern.test(trimmedLine)) {
        filteredLines.push(line);
      }
    }

    return filteredLines.join('\n');
  }

  /**
   * 获取歌词
   * @param songId 歌曲 ID
   * @param forceRefresh 是否强制刷新（忽略缓存）
   */
  public async fetchLyric(songId: number, forceRefresh: boolean = false): Promise<LyricData> {
    if (songId <= 0) {
      throw new Error('Invalid song ID');
    }

    // 检查缓存
    if (!forceRefresh && this.lyricCache.has(songId)) {
      const cached = this.lyricCache.get(songId)!;
      this.currentSongId = songId;
      this.currentLyric = cached;
      this.notifyCallbacks(cached);
      console.info(`[LyricService] Using cached lyric for song ${songId}`);
      return cached;
    }

    console.info(`[LyricService] Fetching lyric for song ${songId}`);

    try {
      // 获取 Cookie 和 csrf_token
      const cookies = await this.getCookies();
      const csrfToken = this.extractCsrfToken(cookies);

      // 构造请求参数
      const requestData: LyricRequestData = {
        id: songId,
        cp: false,
        tv: 0,
        lv: 0,
        rv: 0,
        kv: 0,
        yv: 0,
        ytv: 0,
        yrv: 0
      };

      // 加密参数
      const encryptedParams: EncryptedParams = await NeteaseEncrypt.encrypt(requestData);

      // 构造请求 URL
      const url = `${NETEASE_BASE_URL}${LYRIC_API_PATH}?csrf_token=${csrfToken}`;

      // 发送请求
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': cookies,
          'Referer': 'https://music.163.com/',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        },
        extraData: `params=${encodeURIComponent(encryptedParams.params)}&encSecKey=${encodeURIComponent(encryptedParams.encSecKey)}`
      });

      httpRequest.destroy();

      if (response.responseCode !== 200) {
        throw new Error(`HTTP error: ${response.responseCode}`);
      }

      // 解析响应
      const responseData = JSON.parse(response.result as string) as LyricApiResponse;

      if (responseData.code !== 200) {
        throw new Error(`API error: ${responseData.code}`);
      }

      // 获取原始歌词文本并过滤非标准内容
      const rawLyricOriginal = responseData.lrc?.lyric || '';
      const rawLyric = this.filterLyric(rawLyricOriginal);

      const lyricData: LyricData = {
        songId: songId,
        hasLyric: rawLyric.length > 0,
        rawLyric: rawLyric
      };

      // 缓存结果
      this.lyricCache.set(songId, lyricData);
      this.currentSongId = songId;
      this.currentLyric = lyricData;

      // 通知回调
      this.notifyCallbacks(lyricData);

      console.info(`[LyricService] Fetched lyric for song ${songId}, original: ${rawLyricOriginal.length}, filtered: ${rawLyric.length}`);
      return lyricData;

    } catch (error) {
      console.error(`[LyricService] Failed to fetch lyric for song ${songId}:`, error);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`Failed to fetch lyric: ${String(error)}`);
    }
  }

  /**
   * 清除缓存
   */
  public clearCache(): void {
    this.lyricCache.clear();
    console.info('[LyricService] Cache cleared');
  }

  /**
   * 清除指定歌曲的缓存
   */
  public clearCacheForSong(songId: number): void {
    this.lyricCache.delete(songId);
    console.info(`[LyricService] Cache cleared for song ${songId}`);
  }
}
