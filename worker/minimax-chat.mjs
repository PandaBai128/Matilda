const reasoningEfforts = new Set(["low", "medium", "high", "xhigh", "max"]);
const pointingRequirementMarker = "internal clicky pointing requirement:";
const pointToolName = "point_to_screen";

// This tool reports a location only. The proxy never clicks, types or executes
// model-supplied actions; the existing app remains the owner of the overlay.
const pointTool = {
  name: pointToolName,
  description: "Locate one visible target in the supplied screenshots and report its tight bounding box. Only point; never operate the computer. Report found=false when absent or ambiguous.",
  input_schema: {
    type: "object",
    properties: {
      found: { type: "boolean" },
      screen: { type: "integer", minimum: 1, description: "1-based screenshot order, not physical display ID." },
      bounds: {
        type: "array", items: { type: "number", minimum: 0, maximum: 1000 },
        minItems: 4, maxItems: 4,
        description: "[left, top, right, bottom], normalized 0–1000 within this screenshot. Origin top-left. Tight visible icon/control bounds, not its surrounding panel or filename.",
      },
      label: { type: "string", description: "Short target label." },
      spoken_text: { type: "string", description: "A brief natural answer in the user's language, with no coordinates or claims of clicking." },
    },
    required: ["found", "screen", "bounds", "label", "spoken_text"],
    additionalProperties: false,
  },
};

export function prepareMiniMaxChatRequest(incomingBody, environment) {
  const body = { ...incomingBody, model: environment.MINIMAX_CHAT_MODEL || "MiniMax-M3" };
  const thinkingType = String(environment.MINIMAX_THINKING_TYPE || "disabled").trim().toLowerCase();
  if (/^MiniMax-M3\.1-Flash(?:-Preview)?$/i.test(body.model)) {
    const effort = String(environment.MINIMAX_REASONING_EFFORT || (reasoningEfforts.has(thinkingType) ? thinkingType : "low")).trim().toLowerCase();
    if (!reasoningEfforts.has(effort)) throw new Error("MINIMAX_REASONING_EFFORT must be low, medium, high, xhigh or max.");
    body.thinking = { type: "adaptive" };
    body.output_config = { ...body.output_config, effort };
    // Thinking shares max_tokens with the spoken answer. The app's old 1024
    // budget could end before the first text or pointing tool was produced.
    const tokenBudget = Number(environment.MINIMAX_MAX_TOKENS || 8192);
    if (!Number.isInteger(tokenBudget) || tokenBudget < 8192 || tokenBudget > 524288) {
      throw new Error("MINIMAX_MAX_TOKENS must be an integer from 8192 through 524288.");
    }
    body.max_tokens = Math.max(Number(body.max_tokens) || 0, tokenBudget);
  } else if (thinkingType === "omit") {
    delete body.thinking;
  } else if (thinkingType === "disabled" || thinkingType === "adaptive") {
    body.thinking = { type: thinkingType };
  } else {
    throw new Error("MINIMAX_THINKING_TYPE must be disabled, adaptive or omit for this model.");
  }

  const currentMessage = body.messages?.at(-1);
  const content = currentMessage?.content;
  const pointingBlockIndex = Array.isArray(content) ? content.findIndex(block =>
    block.type === "text" && block.text?.includes(pointingRequirementMarker)) : -1;
  const screenshotCount = Array.isArray(content) ? content.filter(block => block.type === "image").length : 0;
  if (pointingBlockIndex >= 0 && screenshotCount > 0) {
    const originalText = content[pointingBlockIndex].text;
    const userText = originalText.slice(0, originalText.indexOf(pointingRequirementMarker)).trim();
    const toolPrompt = `${userText}\n\nScreen pointing task:
Use point_to_screen exactly once to locate the requested target in the CURRENT screenshots.
There are ${screenshotCount} screenshots, numbered 1 through ${screenshotCount} in image order. Each is a separate complete display; never combine their coordinates.
Inspect the target's visible edges and provide its tight bounding box, normalized 0–1000 on that image. Top-left=(0,0), center=(500,500), bottom-right=(1000,1000).
For a file/folder use the icon bounds, not its filename. For a button use the clickable control bounds. For identifying the current app/page choose its visible identity anchor.
For context-dependent follow-ups, use history only to identify the requested object; locate it afresh in the current images.
If the target is absent, obscured or ambiguous, report found=false. Do not guess from typical layouts.
The application will validate the box and place a marker at its center. Do not generate [POINT...] tags or coordinates in your spoken answer.
You may explain and point only. No clicks, typing, drags, scripts or other computer actions. Supply a brief spoken_text with the tool call.`;
    body.messages = [...body.messages.slice(0, -1), { ...currentMessage, content: content.map((block, index) =>
      index === pointingBlockIndex ? { ...block, text: toolPrompt } : block) }];
    body.tools = [pointTool];
    // MiniMax's documented Anthropic compatibility currently supports auto only.
    body.tool_choice = { type: "auto" };
  }
  return body;
}

export function validatedPointTag(toolInput, screenshotCount) {
  if (toolInput?.found !== true || !Number.isInteger(toolInput.screen)
      || toolInput.screen < 1 || toolInput.screen > screenshotCount) return "[POINT_V2:none]";
  const bounds = toolInput.bounds;
  if (!Array.isArray(bounds) || bounds.length !== 4
      || !bounds.every(value => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1000)
      || bounds[0] >= bounds[2] || bounds[1] >= bounds[3]) return "[POINT_V2:none]";
  const centerX = Math.round((bounds[0] + bounds[2]) / 2);
  const centerY = Math.round((bounds[1] + bounds[3]) / 2);
  const label = String(toolInput.label || "目标").replace(/[\[\]:\r\n]/g, " ").trim().slice(0, 40) || "目标";
  return `[POINT_V2:${centerX},${centerY}:${label}:screen${toolInput.screen}]`;
}

export async function createMiniMaxChatResponse(incomingBody, environment, messagesURL, options = {}) {
  const body = prepareMiniMaxChatRequest(incomingBody, environment);
  const response = await (options.fetchImplementation || fetch)(messagesURL, {
    method: "POST",
    headers: { Authorization: `Bearer ${environment.MINIMAX_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify(body), signal: options.signal,
  });
  if (!response.ok || !body.stream || !response.body) return response;
  const isPointing = body.tools?.some(tool => tool.name === pointToolName) ?? false;
  const screenshotCount = body.messages.at(-1).content.filter?.(block => block.type === "image").length || 0;
  return new Response(adaptChatStream(response.body, isPointing, screenshotCount), {
    status: response.status,
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

function adaptChatStream(upstreamBody, isPointing, screenshotCount) {
  const reader = upstreamBody.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const toolBlocks = new Map();
  let pendingLines = "";
  let accumulatedText = "";
  let emittedCharacterCount = 0;
  let stopReason;
  let hasMessageStop = false;
  let cancelled = false;
  return new ReadableStream({
    async start(controller) {
      function emitText(text) {
        if (!text || cancelled) return;
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } })}\n\n`));
      }
      function emitAvailableText(final = false) {
        const safeText = isPointing ? accumulatedText.split(/\[POINT(?:_V2)?:/)[0] : accumulatedText;
        // Keep a possible split legacy tag prefix out of TTS until the next delta.
        const availableLength = final || !isPointing ? safeText.length : Math.max(0, safeText.length - 12);
        emitText(safeText.slice(emittedCharacterCount, availableLength));
        emittedCharacterCount = Math.max(emittedCharacterCount, availableLength);
      }
      function processLine(line) {
        if (!line.trimStart().startsWith("data:")) return;
        const data = line.trimStart().slice(5).trim();
        if (!data || data === "[DONE]") return;
        const event = JSON.parse(data);
        if (event.type === "error" || event.base_resp?.status_code) {
          throw new Error(event.error?.message || event.base_resp?.status_msg || "MiniMax streaming request failed.");
        }
        if (event.type === "content_block_start") {
          if (event.content_block?.type === "tool_use") {
            toolBlocks.set(event.index, { name: event.content_block.name, input: event.content_block.input, partialJSON: "" });
          } else if (event.content_block?.type === "text") {
            accumulatedText += event.content_block.text || "";
            emitAvailableText();
          }
        } else if (event.type === "content_block_delta") {
          if (event.delta?.type === "text_delta") {
            accumulatedText += event.delta.text || "";
            emitAvailableText();
          } else if (event.delta?.type === "input_json_delta") {
            const toolBlock = toolBlocks.get(event.index);
            if (toolBlock) toolBlock.partialJSON += event.delta.partial_json || "";
          }
        } else if (event.type === "message_delta") {
          stopReason = event.delta?.stop_reason ?? stopReason;
        } else if (event.type === "message_stop") {
          hasMessageStop = true;
        }
      }
      try {
        while (!cancelled) {
          const { done, value } = await reader.read();
          pendingLines += done ? decoder.decode() : decoder.decode(value, { stream: true });
          const lines = pendingLines.split("\n");
          pendingLines = done ? "" : lines.pop() || "";
          for (const line of lines) processLine(line);
          if (done) break;
        }
        if (cancelled) return;
        if (!hasMessageStop) throw new Error("MiniMax stream disconnected before completion.");
        if (stopReason === "max_tokens") throw new Error("MiniMax exhausted the output budget before completing its answer.");
        if (stopReason !== "end_turn" && stopReason !== "tool_use") throw new Error("MiniMax did not complete an answer.");
        emitAvailableText(true);
        if (isPointing) {
          const calls = [...toolBlocks.values()];
          let input;
          if (calls.length === 1 && calls[0].name === pointToolName) {
            try { input = calls[0].partialJSON ? JSON.parse(calls[0].partialJSON) : calls[0].input; } catch { /* Invalid tool input never authorizes a marker. */ }
          }
          const tag = validatedPointTag(input, screenshotCount);
          if (tag === "[POINT_V2:none]") {
            emitText("我还没能确认准确位置。");
          } else if (!accumulatedText.trim()) {
            emitText(String(input.spoken_text || "位置在这里。").split(/\[POINT(?:_V2)?:/)[0]);
          }
          emitText(`\n${tag}`);
        } else if (!accumulatedText.trim() || toolBlocks.size > 0) {
          throw new Error("MiniMax returned no speakable answer.");
        }
        controller.enqueue(encoder.encode('data: {"type":"message_stop"}\n\n'));
        controller.close();
      } catch (error) {
        if (!cancelled) controller.error(error);
        await reader.cancel().catch(() => {});
      } finally {
        reader.releaseLock();
      }
    },
    cancel(reason) {
      cancelled = true;
      return reader.cancel(reason);
    },
  });
}
