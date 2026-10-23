export interface MiniMaxChatEnvironment {
  MINIMAX_API_KEY: string;
  MINIMAX_CHAT_MODEL?: string;
  MINIMAX_THINKING_TYPE?: string;
  MINIMAX_REASONING_EFFORT?: string;
  MINIMAX_MAX_TOKENS?: string;
  MINIMAX_POINTING_MODE?: string;
  MINIMAX_POINTING_PRECISION?: string;
}

export interface MiniMaxComputerPointContext {
  prompt: string;
  screen: number;
  image: { type: string; source: { type: string; media_type: string; data: string } };
  tag: string;
  signal?: AbortSignal;
}

export function prepareMiniMaxChatRequest(
  body: Record<string, unknown>, environment: MiniMaxChatEnvironment,
): Record<string, unknown>;
export function validatedPointTag(input: unknown, screenshotCount: number): string;
export function createMiniMaxChatResponse(
  body: Record<string, unknown>, environment: MiniMaxChatEnvironment, messagesURL: string,
  options?: { signal?: AbortSignal; fetchImplementation?: typeof fetch; refineComputerPoint?: (context: MiniMaxComputerPointContext) => Promise<string> },
): Promise<Response>;
