#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const svgDir = path.join(projectRoot, "Resources", "svg");
const artifactsDir = path.join(
  projectRoot,
  ".claude",
  "phases",
  "core-animation-migration",
  "artifacts"
);
const scanOutputPath = path.join(artifactsDir, "scan-results.json");
const markdownOutputPath = path.join(artifactsDir, "svg-capability-audit.md");

const expectedElements = ["svg", "g", "rect", "use", "defs", "style"];
const knownSubsetElements = ["svg", "g", "rect", "use", "defs", "style"];

function main() {
  fs.mkdirSync(artifactsDir, { recursive: true });

  const files = fs.readdirSync(svgDir)
    .filter((name) => /^clawd-.*\.svg$/i.test(name))
    .sort();

  const results = createEmptyResults(files);

  for (const file of files) {
    const absolutePath = path.join(svgDir, file);
    const markup = fs.readFileSync(absolutePath, "utf8");
    analyzeSVG(file, markup, results);
  }

  finalizeResults(results);

  fs.writeFileSync(scanOutputPath, JSON.stringify(results, null, 2) + "\n", "utf8");
  fs.writeFileSync(markdownOutputPath, buildMarkdown(results) + "\n", "utf8");

  process.stdout.write(
    `Scanned ${results.fileCount} SVG files\n` +
    `JSON: ${path.relative(projectRoot, scanOutputPath)}\n` +
    `Markdown: ${path.relative(projectRoot, markdownOutputPath)}\n`
  );
}

function createEmptyResults(files) {
  const perFile = {};
  for (const file of files) {
    perFile[file] = {
      path: path.join("Resources", "svg", file),
      elements: {},
      attributes: {},
      styleBlocks: [],
      styleLocations: [],
      styleBlockCount: 0,
      cssRuleCount: 0,
      cssRules: [],
      cssDeclarationProperties: [],
      keyframes: [],
      animationBindings: [],
      transformOrigins: [],
      transitions: [],
      inlineStyles: [],
      selectorStats: {
        simpleClass: 0,
        simpleId: 0,
        combined: 0,
        pseudo: 0,
        unsupported: 0
      },
      unexpected: {
        combinedSelectors: [],
        pseudoSelectors: [],
        unsupportedSelectors: [],
        styleOutsideDefs: [],
        customProperties: [],
        valueFunctions: [],
        mediaQueries: [],
        otherAtRules: []
      },
      features: []
    };
  }

  return {
    generatedAt: new Date().toISOString(),
    svgDirectory: path.join("Resources", "svg"),
    fileCount: files.length,
    files,
    expectedElements,
    knownSubsetElements,
    elements: {},
    attributes: {},
    css: {
      properties: {
        rules: {},
        keyframes: {},
        inlineStyles: {}
      },
      keyframes: {},
      animationBindings: [],
      transitions: [],
      transformOrigins: {
        values: {},
        selectors: []
      },
      selectors: {
        simpleClassFiles: [],
        simpleIdFiles: [],
        combinedFiles: [],
        pseudoFiles: [],
        unsupportedFiles: []
      },
      features: {},
      unexpected: {
        combinedSelectors: [],
        pseudoSelectors: [],
        unsupportedSelectors: [],
        styleOutsideDefs: [],
        customProperties: [],
        valueFunctions: [],
        mediaQueries: [],
        otherAtRules: []
      },
      timingFunctions: {},
      fillModes: {},
      iterationCounts: {}
    },
    perFile,
    summary: {}
  };
}

function analyzeSVG(file, markup, results) {
  const document = parseXML(markup);
  const fileResult = results.perFile[file];
  const styleBlocks = [];

  traverseNodes(document.children, [], (node, ancestors) => {
    const elementName = node.name;
    incrementFileCounter(fileResult.elements, elementName);
    incrementGlobalCounter(results.elements, elementName, file, 1);

    for (const [attributeName, attributeValue] of Object.entries(node.attributes)) {
      incrementFileCounter(fileResult.attributes, attributeName);
      incrementGlobalCounter(results.attributes, attributeName, file, 1);

      if (attributeName === "style") {
        const parsedInlineStyle = parseDeclarations(attributeValue);
        const properties = Object.keys(parsedInlineStyle);
        const entry = {
          element: elementName,
          properties,
          declarations: parsedInlineStyle,
          raw: attributeValue
        };

        fileResult.inlineStyles.push(entry);
        for (const property of properties) {
          incrementGlobalCounter(results.css.properties.inlineStyles, property, file, 1);
        }
        recordSpecialDeclarationUsage(file, fileResult, results, parsedInlineStyle, "inline-style");
      }
    }

    if (elementName === "style") {
      const styleText = collectText(node).trim();
      styleBlocks.push(styleText);
      fileResult.styleBlocks.push(styleText);
      fileResult.styleLocations.push(ancestors.concat(elementName));
      fileResult.styleBlockCount += 1;
      const parentName = ancestors[ancestors.length - 1] || "#document";
      if (parentName !== "defs") {
        const marker = ancestors.concat(elementName).join(" > ");
        if (!fileResult.unexpected.styleOutsideDefs.includes(marker)) {
          fileResult.unexpected.styleOutsideDefs.push(marker);
        }
        if (!results.css.unexpected.styleOutsideDefs.includes(`${file}: ${marker}`)) {
          results.css.unexpected.styleOutsideDefs.push(`${file}: ${marker}`);
        }
      }
    }
  });

  for (const cssText of styleBlocks) {
    const parsedCSS = parseCSS(cssText);
    mergeCSSIntoResults(file, fileResult, results, parsedCSS);
  }

  finalizeFileFeatures(fileResult);
}

function traverseNodes(nodes, ancestors, visitor) {
  for (const node of nodes) {
    if (node.type !== "element") {
      continue;
    }

    visitor(node, ancestors);

    if (node.children.length > 0) {
      traverseNodes(node.children, ancestors.concat(node.name), visitor);
    }
  }
}

function collectText(node) {
  let text = "";
  for (const child of node.children) {
    if (child.type === "text") {
      text += child.content;
    } else if (child.type === "element") {
      text += collectText(child);
    }
  }
  return text;
}

function parseXML(markup) {
  const root = createElementNode("#document", {});
  const stack = [root];
  let index = 0;

  while (index < markup.length) {
    const nextTagIndex = markup.indexOf("<", index);
    if (nextTagIndex === -1) {
      appendTextNode(stack[stack.length - 1], markup.slice(index));
      break;
    }

    if (nextTagIndex > index) {
      appendTextNode(stack[stack.length - 1], markup.slice(index, nextTagIndex));
    }

    if (markup.startsWith("<!--", nextTagIndex)) {
      const commentEnd = markup.indexOf("-->", nextTagIndex + 4);
      if (commentEnd === -1) {
        break;
      }
      index = commentEnd + 3;
      continue;
    }

    if (markup.startsWith("<![CDATA[", nextTagIndex)) {
      const cdataEnd = markup.indexOf("]]>", nextTagIndex + 9);
      if (cdataEnd === -1) {
        break;
      }
      appendTextNode(stack[stack.length - 1], markup.slice(nextTagIndex + 9, cdataEnd));
      index = cdataEnd + 3;
      continue;
    }

    if (markup.startsWith("<?", nextTagIndex)) {
      const instructionEnd = markup.indexOf("?>", nextTagIndex + 2);
      if (instructionEnd === -1) {
        break;
      }
      index = instructionEnd + 2;
      continue;
    }

    const tagEnd = findTagEnd(markup, nextTagIndex + 1);
    if (tagEnd === -1) {
      break;
    }

    let tagContent = markup.slice(nextTagIndex + 1, tagEnd).trim();
    index = tagEnd + 1;

    if (!tagContent) {
      continue;
    }

    if (tagContent.startsWith("!")) {
      continue;
    }

    if (tagContent.startsWith("/")) {
      stack.pop();
      continue;
    }

    const selfClosing = /\/\s*$/.test(tagContent);
    if (selfClosing) {
      tagContent = tagContent.replace(/\/\s*$/, "").trim();
    }

    const splitIndex = findNameEnd(tagContent);
    const rawName = splitIndex === -1 ? tagContent : tagContent.slice(0, splitIndex);
    const attributeSource = splitIndex === -1 ? "" : tagContent.slice(splitIndex).trim();
    const node = createElementNode(normalizeName(rawName), parseAttributes(attributeSource));

    stack[stack.length - 1].children.push(node);

    if (!selfClosing) {
      stack.push(node);
    }
  }

  return root;
}

function createElementNode(name, attributes) {
  return {
    type: "element",
    name,
    attributes,
    children: []
  };
}

function appendTextNode(parent, content) {
  if (!content) {
    return;
  }

  parent.children.push({
    type: "text",
    content
  });
}

function findTagEnd(markup, startIndex) {
  let quote = null;

  for (let index = startIndex; index < markup.length; index += 1) {
    const character = markup[index];

    if (quote) {
      if (character === quote && markup[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === ">") {
      return index;
    }
  }

  return -1;
}

function findNameEnd(source) {
  for (let index = 0; index < source.length; index += 1) {
    if (/\s/.test(source[index])) {
      return index;
    }
  }
  return -1;
}

function parseAttributes(source) {
  const attributes = {};
  let index = 0;

  while (index < source.length) {
    while (index < source.length && /\s/.test(source[index])) {
      index += 1;
    }

    if (index >= source.length) {
      break;
    }

    let nameStart = index;
    while (index < source.length && !/[\s=]/.test(source[index])) {
      index += 1;
    }
    const rawName = source.slice(nameStart, index);
    const name = normalizeName(rawName);

    while (index < source.length && /\s/.test(source[index])) {
      index += 1;
    }

    let value = "";
    if (source[index] === "=") {
      index += 1;
      while (index < source.length && /\s/.test(source[index])) {
        index += 1;
      }

      if (source[index] === "\"" || source[index] === "'") {
        const quote = source[index];
        index += 1;
        const valueStart = index;
        while (index < source.length && source[index] !== quote) {
          index += 1;
        }
        value = source.slice(valueStart, index);
        index += 1;
      } else {
        const valueStart = index;
        while (index < source.length && !/\s/.test(source[index])) {
          index += 1;
        }
        value = source.slice(valueStart, index);
      }
    }

    if (name) {
      attributes[name] = value;
    }
  }

  return attributes;
}

function normalizeName(name) {
  return name.trim();
}

function parseCSS(cssText) {
  const source = stripCSSComments(cssText);
  const rules = [];
  const keyframes = [];
  const unexpected = {
    combinedSelectors: [],
    pseudoSelectors: [],
    unsupportedSelectors: [],
    mediaQueries: [],
    otherAtRules: []
  };
  let index = 0;

  while (index < source.length) {
    index = skipWhitespace(source, index);
    if (index >= source.length) {
      break;
    }

    if (source[index] === "@") {
      const atRuleStart = index;
      const braceIndex = findNextTopLevel(source, "{", index);
      if (braceIndex === -1) {
        break;
      }

      const prelude = source.slice(index, braceIndex).trim();
      const block = readBalancedBlock(source, braceIndex);
      if (!block) {
        break;
      }

      const lowerPrelude = prelude.toLowerCase();
      if (lowerPrelude.startsWith("@keyframes")) {
        const keyframeName = prelude.slice("@keyframes".length).trim();
        keyframes.push(parseKeyframes(keyframeName, block.content));
      } else if (lowerPrelude.startsWith("@media")) {
        unexpected.mediaQueries.push({
          atRule: prelude,
          raw: source.slice(atRuleStart, block.endIndex + 1)
        });
      } else {
        unexpected.otherAtRules.push({
          atRule: prelude,
          raw: source.slice(atRuleStart, block.endIndex + 1)
        });
      }

      index = block.endIndex + 1;
      continue;
    }

    const braceIndex = findNextTopLevel(source, "{", index);
    if (braceIndex === -1) {
      break;
    }

    const selectorText = source.slice(index, braceIndex).trim();
    const block = readBalancedBlock(source, braceIndex);
    if (!block) {
      break;
    }

    const selectors = splitCommaAware(selectorText).map((selector) => selector.trim()).filter(Boolean);
    const declarations = parseDeclarations(block.content);
    const selectorDetails = selectors.map((selector) => classifySelector(selector));

    for (const detail of selectorDetails) {
      if (detail.isCombined) {
        unexpected.combinedSelectors.push(detail.raw);
      }
      if (detail.hasPseudo) {
        unexpected.pseudoSelectors.push(detail.raw);
      }
      if (detail.type === "unsupported") {
        unexpected.unsupportedSelectors.push(detail.raw);
      }
    }

    rules.push({
      selectorText,
      selectors,
      selectorDetails,
      declarations
    });

    index = block.endIndex + 1;
  }

  return { rules, keyframes, unexpected };
}

function stripCSSComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, "");
}

function skipWhitespace(source, index) {
  while (index < source.length && /\s/.test(source[index])) {
    index += 1;
  }
  return index;
}

function findNextTopLevel(source, target, startIndex) {
  let depthParen = 0;
  let depthBracket = 0;
  let quote = null;

  for (let index = startIndex; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (character === quote && source[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === "(") {
      depthParen += 1;
      continue;
    }
    if (character === ")") {
      depthParen = Math.max(0, depthParen - 1);
      continue;
    }
    if (character === "[") {
      depthBracket += 1;
      continue;
    }
    if (character === "]") {
      depthBracket = Math.max(0, depthBracket - 1);
      continue;
    }

    if (depthParen === 0 && depthBracket === 0 && character === target) {
      return index;
    }
  }

  return -1;
}

function readBalancedBlock(source, openBraceIndex) {
  let depth = 0;
  let quote = null;

  for (let index = openBraceIndex; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (character === quote && source[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === "{") {
      depth += 1;
      continue;
    }

    if (character === "}") {
      depth -= 1;
      if (depth === 0) {
        return {
          content: source.slice(openBraceIndex + 1, index),
          endIndex: index
        };
      }
    }
  }

  return null;
}

function parseKeyframes(name, body) {
  const frames = [];
  const properties = new Set();
  let index = 0;

  while (index < body.length) {
    index = skipWhitespace(body, index);
    if (index >= body.length) {
      break;
    }

    const braceIndex = findNextTopLevel(body, "{", index);
    if (braceIndex === -1) {
      break;
    }

    const selectorText = body.slice(index, braceIndex).trim();
    const block = readBalancedBlock(body, braceIndex);
    if (!block) {
      break;
    }

    const declarations = parseDeclarations(block.content);
    for (const property of Object.keys(declarations)) {
      properties.add(property);
    }

    const stops = splitCommaAware(selectorText).map((item) => item.trim()).filter(Boolean);
    frames.push({
      selectorText,
      stops,
      declarations
    });

    index = block.endIndex + 1;
  }

  return {
    name,
    frameCount: frames.length,
    stopCount: frames.reduce((count, frame) => count + frame.stops.length, 0),
    properties: Array.from(properties).sort(),
    frames
  };
}

function parseDeclarations(source) {
  const declarations = {};
  const segments = splitBySemicolonAware(source);

  for (const segment of segments) {
    const declaration = segment.trim();
    if (!declaration) {
      continue;
    }

    const colonIndex = findNextTopLevel(declaration, ":", 0);
    if (colonIndex === -1) {
      continue;
    }

    const property = declaration.slice(0, colonIndex).trim();
    const value = declaration.slice(colonIndex + 1).trim();
    if (property) {
      declarations[property] = value;
    }
  }

  return declarations;
}

function splitBySemicolonAware(source) {
  const items = [];
  let startIndex = 0;
  let depthParen = 0;
  let depthBracket = 0;
  let quote = null;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (character === quote && source[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === "(") {
      depthParen += 1;
      continue;
    }
    if (character === ")") {
      depthParen = Math.max(0, depthParen - 1);
      continue;
    }
    if (character === "[") {
      depthBracket += 1;
      continue;
    }
    if (character === "]") {
      depthBracket = Math.max(0, depthBracket - 1);
      continue;
    }

    if (character === ";" && depthParen === 0 && depthBracket === 0) {
      items.push(source.slice(startIndex, index));
      startIndex = index + 1;
    }
  }

  items.push(source.slice(startIndex));
  return items;
}

function splitCommaAware(source) {
  return splitAware(source, ",");
}

function splitWhitespaceAware(source) {
  const items = [];
  let current = "";
  let depthParen = 0;
  let depthBracket = 0;
  let quote = null;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      current += character;
      if (character === quote && source[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      current += character;
      continue;
    }

    if (character === "(") {
      depthParen += 1;
      current += character;
      continue;
    }
    if (character === ")") {
      depthParen = Math.max(0, depthParen - 1);
      current += character;
      continue;
    }
    if (character === "[") {
      depthBracket += 1;
      current += character;
      continue;
    }
    if (character === "]") {
      depthBracket = Math.max(0, depthBracket - 1);
      current += character;
      continue;
    }

    if (/\s/.test(character) && depthParen === 0 && depthBracket === 0) {
      if (current.trim()) {
        items.push(current.trim());
        current = "";
      }
      continue;
    }

    current += character;
  }

  if (current.trim()) {
    items.push(current.trim());
  }

  return items;
}

function splitAware(source, delimiter) {
  const items = [];
  let startIndex = 0;
  let depthParen = 0;
  let depthBracket = 0;
  let quote = null;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (character === quote && source[index - 1] !== "\\") {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === "(") {
      depthParen += 1;
      continue;
    }
    if (character === ")") {
      depthParen = Math.max(0, depthParen - 1);
      continue;
    }
    if (character === "[") {
      depthBracket += 1;
      continue;
    }
    if (character === "]") {
      depthBracket = Math.max(0, depthBracket - 1);
      continue;
    }

    if (character === delimiter && depthParen === 0 && depthBracket === 0) {
      items.push(source.slice(startIndex, index));
      startIndex = index + 1;
    }
  }

  items.push(source.slice(startIndex));
  return items;
}

function classifySelector(selector) {
  const raw = selector.trim();
  const hasPseudo = /:(?!:)/.test(raw);
  const isCombined = /[\s>+~]/.test(raw) || /[#.][^#.\s>+~]+[#.]/.test(raw);

  if (/^\.[A-Za-z0-9_-]+$/.test(raw)) {
    return { raw, type: "class", hasPseudo, isCombined };
  }
  if (/^#[A-Za-z0-9_-]+$/.test(raw)) {
    return { raw, type: "id", hasPseudo, isCombined };
  }

  return { raw, type: "unsupported", hasPseudo, isCombined };
}

function parseAnimationBindings(declarations) {
  const shorthandValues = declarations.animation
    ? splitCommaAware(declarations.animation).map((item) => item.trim()).filter(Boolean)
    : [];
  const names = declarations["animation-name"]
    ? splitCommaAware(declarations["animation-name"]).map((item) => item.trim())
    : [];
  const durations = declarations["animation-duration"]
    ? splitCommaAware(declarations["animation-duration"]).map((item) => item.trim())
    : [];
  const timings = declarations["animation-timing-function"]
    ? splitCommaAware(declarations["animation-timing-function"]).map((item) => item.trim())
    : [];
  const iterations = declarations["animation-iteration-count"]
    ? splitCommaAware(declarations["animation-iteration-count"]).map((item) => item.trim())
    : [];
  const delays = declarations["animation-delay"]
    ? splitCommaAware(declarations["animation-delay"]).map((item) => item.trim())
    : [];
  const fillModes = declarations["animation-fill-mode"]
    ? splitCommaAware(declarations["animation-fill-mode"]).map((item) => item.trim())
    : [];

  const bindingCount = Math.max(
    shorthandValues.length,
    names.length,
    durations.length,
    timings.length,
    iterations.length,
    delays.length,
    fillModes.length
  );

  if (bindingCount === 0) {
    return [];
  }

  const bindings = [];
  for (let index = 0; index < bindingCount; index += 1) {
    const shorthand = shorthandValues[index] || "";
    const parsedShorthand = shorthand ? parseAnimationShorthand(shorthand) : {};
    bindings.push({
      raw: shorthand || null,
      name: pickIndexedValue(names, index) || parsedShorthand.name || null,
      duration: pickIndexedValue(durations, index) || parsedShorthand.duration || null,
      timingFunction: pickIndexedValue(timings, index) || parsedShorthand.timingFunction || null,
      iterationCount: pickIndexedValue(iterations, index) || parsedShorthand.iterationCount || null,
      delay: pickIndexedValue(delays, index) || parsedShorthand.delay || null,
      fillMode: pickIndexedValue(fillModes, index) || parsedShorthand.fillMode || null,
      extraTokens: parsedShorthand.extraTokens || []
    });
  }

  return bindings;
}

function parseAnimationShorthand(value) {
  const tokens = splitWhitespaceAware(value);
  const result = {
    name: null,
    duration: null,
    timingFunction: null,
    iterationCount: null,
    delay: null,
    fillMode: null,
    extraTokens: []
  };

  for (const token of tokens) {
    if (isTimeToken(token)) {
      if (!result.duration) {
        result.duration = token;
      } else if (!result.delay) {
        result.delay = token;
      } else {
        result.extraTokens.push(token);
      }
      continue;
    }

    if (isTimingFunction(token) && !result.timingFunction) {
      result.timingFunction = token;
      continue;
    }

    if (isIterationCount(token) && !result.iterationCount) {
      result.iterationCount = token;
      continue;
    }

    if (isFillMode(token) && !result.fillMode) {
      result.fillMode = token;
      continue;
    }

    if (isDirectionToken(token) || isPlayStateToken(token)) {
      result.extraTokens.push(token);
      continue;
    }

    if (!result.name) {
      result.name = token;
    } else {
      result.extraTokens.push(token);
    }
  }

  return result;
}

function parseTransitionBindings(declarations) {
  const transitionValues = declarations.transition
    ? splitCommaAware(declarations.transition).map((item) => item.trim()).filter(Boolean)
    : [];

  if (transitionValues.length === 0 && !declarations["transition-property"]) {
    return [];
  }

  const properties = declarations["transition-property"]
    ? splitCommaAware(declarations["transition-property"]).map((item) => item.trim())
    : [];
  const durations = declarations["transition-duration"]
    ? splitCommaAware(declarations["transition-duration"]).map((item) => item.trim())
    : [];
  const timings = declarations["transition-timing-function"]
    ? splitCommaAware(declarations["transition-timing-function"]).map((item) => item.trim())
    : [];
  const delays = declarations["transition-delay"]
    ? splitCommaAware(declarations["transition-delay"]).map((item) => item.trim())
    : [];

  const transitionCount = Math.max(transitionValues.length, properties.length, durations.length, timings.length, delays.length);
  const transitions = [];

  for (let index = 0; index < transitionCount; index += 1) {
    const raw = transitionValues[index] || null;
    const parsedShorthand = raw ? parseTransitionShorthand(raw) : {};
    transitions.push({
      raw,
      property: pickIndexedValue(properties, index) || parsedShorthand.property || null,
      duration: pickIndexedValue(durations, index) || parsedShorthand.duration || null,
      timingFunction: pickIndexedValue(timings, index) || parsedShorthand.timingFunction || null,
      delay: pickIndexedValue(delays, index) || parsedShorthand.delay || null
    });
  }

  return transitions;
}

function parseTransitionShorthand(value) {
  const tokens = splitWhitespaceAware(value);
  const result = {
    property: null,
    duration: null,
    timingFunction: null,
    delay: null
  };

  for (const token of tokens) {
    if (isTimeToken(token)) {
      if (!result.duration) {
        result.duration = token;
      } else if (!result.delay) {
        result.delay = token;
      }
      continue;
    }

    if (isTimingFunction(token) && !result.timingFunction) {
      result.timingFunction = token;
      continue;
    }

    if (!result.property) {
      result.property = token;
    }
  }

  return result;
}

function mergeCSSIntoResults(file, fileResult, results, parsedCSS) {
  const cssProperties = new Set(fileResult.cssDeclarationProperties);

  for (const rule of parsedCSS.rules) {
    fileResult.cssRuleCount += 1;
    fileResult.cssRules.push({
      selectorText: rule.selectorText,
      declarations: rule.declarations
    });

    for (const property of Object.keys(rule.declarations)) {
      cssProperties.add(property);
      incrementGlobalCounter(results.css.properties.rules, property, file, 1);
    }
    recordSpecialDeclarationUsage(file, fileResult, results, rule.declarations, "rule");

    for (const selectorDetail of rule.selectorDetails) {
      if (selectorDetail.type === "class") {
        fileResult.selectorStats.simpleClass += 1;
      } else if (selectorDetail.type === "id") {
        fileResult.selectorStats.simpleId += 1;
      } else {
        fileResult.selectorStats.unsupported += 1;
      }

      if (selectorDetail.isCombined) {
        fileResult.selectorStats.combined += 1;
      }
      if (selectorDetail.hasPseudo) {
        fileResult.selectorStats.pseudo += 1;
      }
    }

    if (rule.declarations["transform-origin"]) {
      const transformOrigin = {
        selectorText: rule.selectorText,
        selectors: rule.selectors,
        value: rule.declarations["transform-origin"]
      };
      fileResult.transformOrigins.push(transformOrigin);
      addFileToFeature(results.css.transformOrigins.values, transformOrigin.value, file);
      results.css.transformOrigins.selectors.push({
        file,
        selectorText: rule.selectorText,
        value: transformOrigin.value
      });
    }

    const transitions = parseTransitionBindings(rule.declarations);
    for (const transition of transitions) {
      const entry = {
        file,
        selectorText: rule.selectorText,
        selectors: rule.selectors,
        ...transition
      };
      fileResult.transitions.push(entry);
      results.css.transitions.push(entry);
      if (transition.timingFunction) {
        addFileToFeature(results.css.timingFunctions, transition.timingFunction, file);
      }
    }

    const animationBindings = parseAnimationBindings(rule.declarations);
    for (const selectorDetail of rule.selectorDetails) {
      for (const binding of animationBindings) {
        const entry = {
          file,
          selector: selectorDetail.raw,
          selectorType: selectorDetail.type,
          duration: binding.duration,
          timingFunction: binding.timingFunction,
          iterationCount: binding.iterationCount,
          delay: binding.delay,
          fillMode: binding.fillMode,
          name: binding.name,
          raw: binding.raw,
          extraTokens: binding.extraTokens
        };

        fileResult.animationBindings.push(entry);
        results.css.animationBindings.push(entry);

        if (binding.timingFunction) {
          addFileToFeature(results.css.timingFunctions, binding.timingFunction, file);
        }
        if (binding.fillMode) {
          addFileToFeature(results.css.fillModes, binding.fillMode, file);
        }
        if (binding.iterationCount) {
          addFileToFeature(results.css.iterationCounts, binding.iterationCount, file);
        }
      }
    }
  }

  for (const keyframe of parsedCSS.keyframes) {
    fileResult.keyframes.push(keyframe);
    addKeyframeSummary(results.css.keyframes, keyframe, file);
    for (const property of keyframe.properties) {
      incrementGlobalCounter(results.css.properties.keyframes, property, file, 1);
    }
    for (const frame of keyframe.frames) {
      recordSpecialDeclarationUsage(file, fileResult, results, frame.declarations, "keyframe");
    }
  }

  fileResult.cssDeclarationProperties = Array.from(cssProperties).sort();

  mergeUnexpected(fileResult.unexpected.combinedSelectors, parsedCSS.unexpected.combinedSelectors);
  mergeUnexpected(fileResult.unexpected.pseudoSelectors, parsedCSS.unexpected.pseudoSelectors);
  mergeUnexpected(fileResult.unexpected.unsupportedSelectors, parsedCSS.unexpected.unsupportedSelectors);
  mergeUnexpectedObjects(fileResult.unexpected.mediaQueries, parsedCSS.unexpected.mediaQueries);
  mergeUnexpectedObjects(fileResult.unexpected.otherAtRules, parsedCSS.unexpected.otherAtRules);

  mergeUnexpected(results.css.unexpected.combinedSelectors, parsedCSS.unexpected.combinedSelectors.map((selector) => `${file}: ${selector}`));
  mergeUnexpected(results.css.unexpected.pseudoSelectors, parsedCSS.unexpected.pseudoSelectors.map((selector) => `${file}: ${selector}`));
  mergeUnexpected(results.css.unexpected.unsupportedSelectors, parsedCSS.unexpected.unsupportedSelectors.map((selector) => `${file}: ${selector}`));
  mergeUnexpectedObjects(
    results.css.unexpected.mediaQueries,
    parsedCSS.unexpected.mediaQueries.map((entry) => ({ file, ...entry }))
  );
  mergeUnexpectedObjects(
    results.css.unexpected.otherAtRules,
    parsedCSS.unexpected.otherAtRules.map((entry) => ({ file, ...entry }))
  );
}

function recordSpecialDeclarationUsage(file, fileResult, results, declarations, sourceKind) {
  for (const [property, value] of Object.entries(declarations)) {
    if (property.startsWith("--")) {
      const label = `${sourceKind}:${property}`;
      if (!fileResult.unexpected.customProperties.includes(label)) {
        fileResult.unexpected.customProperties.push(label);
      }
      if (!results.css.unexpected.customProperties.includes(`${file}: ${label}`)) {
        results.css.unexpected.customProperties.push(`${file}: ${label}`);
      }
    }

    const valueFunctions = [];
    if (/\bvar\(/i.test(value)) {
      valueFunctions.push("var()");
    }
    if (/\bcalc\(/i.test(value)) {
      valueFunctions.push("calc()");
    }

    for (const fn of valueFunctions) {
      const label = `${sourceKind}:${property}:${fn}`;
      if (!fileResult.unexpected.valueFunctions.includes(label)) {
        fileResult.unexpected.valueFunctions.push(label);
      }
      if (!results.css.unexpected.valueFunctions.includes(`${file}: ${label}`)) {
        results.css.unexpected.valueFunctions.push(`${file}: ${label}`);
      }
    }
  }
}

function addKeyframeSummary(target, keyframe, file) {
  if (!target[keyframe.name]) {
    target[keyframe.name] = {
      files: [],
      stopCounts: {},
      propertyUsage: {},
      maxStopCount: 0
    };
  }

  const entry = target[keyframe.name];
  if (!entry.files.includes(file)) {
    entry.files.push(file);
    entry.files.sort();
  }
  entry.stopCounts[file] = keyframe.stopCount;
  entry.maxStopCount = Math.max(entry.maxStopCount, keyframe.stopCount);

  for (const property of keyframe.properties) {
    if (!entry.propertyUsage[property]) {
      entry.propertyUsage[property] = [];
    }
    if (!entry.propertyUsage[property].includes(file)) {
      entry.propertyUsage[property].push(file);
      entry.propertyUsage[property].sort();
    }
  }
}

function mergeUnexpected(target, items) {
  for (const item of items) {
    if (!target.includes(item)) {
      target.push(item);
    }
  }
}

function mergeUnexpectedObjects(target, items) {
  for (const item of items) {
    const serialized = JSON.stringify(item);
    if (!target.some((entry) => JSON.stringify(entry) === serialized)) {
      target.push(item);
    }
  }
}

function finalizeFileFeatures(fileResult) {
  const features = new Set();

  if (fileResult.styleBlockCount > 0) {
    features.add("style-block");
  }
  if (fileResult.keyframes.length > 0) {
    features.add("@keyframes");
  }
  if (fileResult.animationBindings.length > 0) {
    features.add("animation-binding");
  }
  if (fileResult.transformOrigins.length > 0) {
    features.add("transform-origin");
  }
  if (fileResult.transitions.length > 0) {
    features.add("transition");
  }
  if (fileResult.inlineStyles.length > 0) {
    features.add("inline-style-attr");
  }
  if (fileResult.selectorStats.simpleClass > 0) {
    features.add("selector:.class");
  }
  if (fileResult.selectorStats.simpleId > 0) {
    features.add("selector:#id");
  }
  if (fileResult.selectorStats.combined > 0) {
    features.add("selector:combined");
  }
  if (fileResult.selectorStats.pseudo > 0) {
    features.add("selector:pseudo");
  }
  if (fileResult.selectorStats.unsupported > 0) {
    features.add("selector:unsupported");
  }
  if (fileResult.unexpected.mediaQueries.length > 0) {
    features.add("@media");
  }
  if (fileResult.unexpected.otherAtRules.length > 0) {
    features.add("other-at-rule");
  }
  if (fileResult.unexpected.styleOutsideDefs.length > 0) {
    features.add("style-outside-defs");
  }
  if (fileResult.unexpected.customProperties.length > 0) {
    features.add("custom-property");
  }
  if (fileResult.unexpected.valueFunctions.some((entry) => entry.endsWith(":var()"))) {
    features.add("value:var()");
  }
  if (fileResult.unexpected.valueFunctions.some((entry) => entry.endsWith(":calc()"))) {
    features.add("value:calc()");
  }
  if (fileResult.animationBindings.some((binding) => binding.delay && binding.delay !== "0s" && binding.delay !== "0ms")) {
    features.add("animation-delay");
  }
  if (fileResult.animationBindings.some((binding) => binding.fillMode === "forwards")) {
    features.add("fill-mode:forwards");
  }
  if (fileResult.animationBindings.some((binding) => binding.iterationCount === "infinite")) {
    features.add("iteration:infinite");
  }
  if (fileResult.animationBindings.some((binding) => binding.iterationCount === "1")) {
    features.add("iteration:1");
  }
  if (fileResult.animationBindings.some((binding) => binding.timingFunction === "ease-in-out")) {
    features.add("timing:ease-in-out");
  }
  if (fileResult.animationBindings.some((binding) => binding.timingFunction === "linear")) {
    features.add("timing:linear");
  }
  if (fileResult.animationBindings.some((binding) => binding.timingFunction === "ease-out")) {
    features.add("timing:ease-out");
  }
  if (fileResult.animationBindings.some((binding) => binding.timingFunction && binding.timingFunction.startsWith("cubic-bezier("))) {
    features.add("timing:cubic-bezier");
  }
  if (fileResult.animationBindings.some((binding) => binding.timingFunction && binding.timingFunction.startsWith("steps("))) {
    features.add("timing:steps");
  }
  if (fileResult.cssDeclarationProperties.includes("animation-name")
    || fileResult.cssDeclarationProperties.includes("animation-duration")
    || fileResult.cssDeclarationProperties.includes("animation-timing-function")
    || fileResult.cssDeclarationProperties.includes("animation-iteration-count")
    || fileResult.cssDeclarationProperties.includes("animation-fill-mode")) {
    features.add("animation-longhand");
  }
  if (fileResult.cssDeclarationProperties.includes("transform-box")) {
    features.add("transform-box");
  }
  if (fileResult.cssDeclarationProperties.includes("mix-blend-mode")) {
    features.add("mix-blend-mode");
  }
  if (fileResult.cssDeclarationProperties.includes("visibility")) {
    features.add("rule:visibility");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("transform"))) {
    features.add("keyframes:transform");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("opacity"))) {
    features.add("keyframes:opacity");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("fill"))) {
    features.add("keyframes:fill");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("stroke-width"))) {
    features.add("keyframes:stroke-width");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("r"))) {
    features.add("keyframes:r");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("width"))) {
    features.add("keyframes:width");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.properties.includes("visibility"))) {
    features.add("keyframes:visibility");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.stopCount >= 10)) {
    features.add("keyframes:10+ stops");
  }
  if (fileResult.keyframes.some((keyframe) => keyframe.stopCount >= 15)) {
    features.add("keyframes:15+ stops");
  }

  fileResult.features = Array.from(features).sort();
}

function finalizeResults(results) {
  for (const file of results.files) {
    const fileResult = results.perFile[file];

    addFeature(results.css.features, "style-block", fileResult.styleBlockCount > 0, file);
    addFeature(results.css.features, "@keyframes", fileResult.keyframes.length > 0, file);
    addFeature(results.css.features, "animation-binding", fileResult.animationBindings.length > 0, file);
    addFeature(results.css.features, "transform-origin", fileResult.transformOrigins.length > 0, file);
    addFeature(results.css.features, "transition", fileResult.transitions.length > 0, file);
    addFeature(results.css.features, "inline-style-attr", fileResult.inlineStyles.length > 0, file);
    addFeature(results.css.features, "selector:.class", fileResult.selectorStats.simpleClass > 0, file);
    addFeature(results.css.features, "selector:#id", fileResult.selectorStats.simpleId > 0, file);
    addFeature(results.css.features, "selector:combined", fileResult.selectorStats.combined > 0, file);
    addFeature(results.css.features, "selector:pseudo", fileResult.selectorStats.pseudo > 0, file);
    addFeature(results.css.features, "selector:unsupported", fileResult.selectorStats.unsupported > 0, file);
    addFeature(results.css.features, "@media", fileResult.unexpected.mediaQueries.length > 0, file);
    addFeature(results.css.features, "other-at-rule", fileResult.unexpected.otherAtRules.length > 0, file);
    addFeature(results.css.features, "style-outside-defs", fileResult.unexpected.styleOutsideDefs.length > 0, file);
    addFeature(results.css.features, "custom-property", fileResult.unexpected.customProperties.length > 0, file);
    addFeature(
      results.css.features,
      "value:var()",
      fileResult.unexpected.valueFunctions.some((entry) => entry.endsWith(":var()")),
      file
    );
    addFeature(
      results.css.features,
      "value:calc()",
      fileResult.unexpected.valueFunctions.some((entry) => entry.endsWith(":calc()")),
      file
    );
    addFeature(
      results.css.features,
      "animation-delay",
      fileResult.animationBindings.some((binding) => binding.delay && binding.delay !== "0s" && binding.delay !== "0ms"),
      file
    );
    addFeature(
      results.css.features,
      "fill-mode:forwards",
      fileResult.animationBindings.some((binding) => binding.fillMode === "forwards"),
      file
    );
    addFeature(
      results.css.features,
      "iteration:infinite",
      fileResult.animationBindings.some((binding) => binding.iterationCount === "infinite"),
      file
    );
    addFeature(
      results.css.features,
      "iteration:1",
      fileResult.animationBindings.some((binding) => binding.iterationCount === "1"),
      file
    );
    addFeature(
      results.css.features,
      "timing:ease-in-out",
      fileResult.animationBindings.some((binding) => binding.timingFunction === "ease-in-out"),
      file
    );
    addFeature(
      results.css.features,
      "timing:linear",
      fileResult.animationBindings.some((binding) => binding.timingFunction === "linear"),
      file
    );
    addFeature(
      results.css.features,
      "timing:ease-out",
      fileResult.animationBindings.some((binding) => binding.timingFunction === "ease-out"),
      file
    );
    addFeature(
      results.css.features,
      "timing:cubic-bezier",
      fileResult.animationBindings.some((binding) => binding.timingFunction && binding.timingFunction.startsWith("cubic-bezier(")),
      file
    );
    addFeature(
      results.css.features,
      "timing:steps",
      fileResult.animationBindings.some((binding) => binding.timingFunction && binding.timingFunction.startsWith("steps(")),
      file
    );
    addFeature(
      results.css.features,
      "animation-longhand",
      fileResult.cssDeclarationProperties.includes("animation-name")
        || fileResult.cssDeclarationProperties.includes("animation-duration")
        || fileResult.cssDeclarationProperties.includes("animation-timing-function")
        || fileResult.cssDeclarationProperties.includes("animation-iteration-count")
        || fileResult.cssDeclarationProperties.includes("animation-fill-mode"),
      file
    );
    addFeature(
      results.css.features,
      "transform-box",
      fileResult.cssDeclarationProperties.includes("transform-box"),
      file
    );
    addFeature(
      results.css.features,
      "mix-blend-mode",
      fileResult.cssDeclarationProperties.includes("mix-blend-mode"),
      file
    );
    addFeature(
      results.css.features,
      "rule:visibility",
      fileResult.cssDeclarationProperties.includes("visibility"),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:transform",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("transform")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:opacity",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("opacity")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:fill",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("fill")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:stroke-width",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("stroke-width")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:r",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("r")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:width",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("width")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:visibility",
      fileResult.keyframes.some((keyframe) => keyframe.properties.includes("visibility")),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:10+ stops",
      fileResult.keyframes.some((keyframe) => keyframe.stopCount >= 10),
      file
    );
    addFeature(
      results.css.features,
      "keyframes:15+ stops",
      fileResult.keyframes.some((keyframe) => keyframe.stopCount >= 15),
      file
    );
  }

  results.css.selectors.simpleClassFiles = getFeatureFiles(results.css.features, "selector:.class");
  results.css.selectors.simpleIdFiles = getFeatureFiles(results.css.features, "selector:#id");
  results.css.selectors.combinedFiles = getFeatureFiles(results.css.features, "selector:combined");
  results.css.selectors.pseudoFiles = getFeatureFiles(results.css.features, "selector:pseudo");
  results.css.selectors.unsupportedFiles = getFeatureFiles(results.css.features, "selector:unsupported");

  const actualElements = Object.keys(results.elements).sort();
  const unexpectedElements = actualElements.filter((element) => !knownSubsetElements.includes(element));
  const actualAttributes = Object.keys(results.attributes).sort();
  const maxKeyframeStopCount = Object.values(results.css.keyframes)
    .reduce((max, keyframe) => Math.max(max, keyframe.maxStopCount), 0);
  const maxKeyframeFiles = Object.entries(results.css.keyframes)
    .filter(([, keyframe]) => keyframe.maxStopCount === maxKeyframeStopCount)
    .map(([name, keyframe]) => ({ name, files: keyframe.files, maxStopCount: keyframe.maxStopCount }));
  const transitionFiles = getFeatureFiles(results.css.features, "transition");

  results.summary = {
    actualElements,
    unexpectedElements,
    actualAttributes,
    selectorComplexity: {
      simpleClassFiles: results.css.selectors.simpleClassFiles,
      simpleIdFiles: results.css.selectors.simpleIdFiles,
      combinedFiles: results.css.selectors.combinedFiles,
      pseudoFiles: results.css.selectors.pseudoFiles,
      unsupportedFiles: results.css.selectors.unsupportedFiles
    },
    maxKeyframeStopCount,
    maxKeyframeFiles,
    transitionFiles,
    styleOutsideDefsFiles: getFeatureFiles(results.css.features, "style-outside-defs"),
    customPropertyFiles: getFeatureFiles(results.css.features, "custom-property"),
    varFunctionFiles: getFeatureFiles(results.css.features, "value:var()"),
    calcFunctionFiles: getFeatureFiles(results.css.features, "value:calc()"),
    animationLonghandFiles: getFeatureFiles(results.css.features, "animation-longhand"),
    transformBoxFiles: getFeatureFiles(results.css.features, "transform-box"),
    mixBlendModeFiles: getFeatureFiles(results.css.features, "mix-blend-mode"),
    specialMarkers: summarizeSpecialMarkers(results),
    parserMinimumCapability: summarizeParserCapabilities(results)
  };
}

function summarizeSpecialMarkers(results) {
  const markers = {};
  for (const marker of ["#eyes-js", "#body-js", "#shadow-js"]) {
    markers[marker] = [];
  }

  for (const file of results.files) {
    const fileResult = results.perFile[file];
    const elementHasMarker = (marker) => {
      return fileResult.cssRules.some((rule) => rule.selectorText.includes(marker))
        || fileContainsIdMarker(file, marker);
    };

    for (const marker of Object.keys(markers)) {
      if (elementHasMarker(marker)) {
        markers[marker].push(file);
      }
    }
  }

  return markers;
}

function fileContainsIdMarker(file, marker) {
  const markup = fs.readFileSync(path.join(svgDir, file), "utf8");
  return markup.includes(`id="${marker.slice(1)}"`);
}

function summarizeParserCapabilities(results) {
  const elementSupport = Object.keys(results.elements).sort();
  const cssProperties = new Set([
    ...Object.keys(results.css.properties.rules),
    ...Object.keys(results.css.properties.keyframes),
    ...Object.keys(results.css.properties.inlineStyles)
  ]);

  return {
    elements: elementSupport,
    cssProperties: Array.from(cssProperties).sort(),
    selectorTypes: {
      simpleClassOnly: results.css.selectors.unsupportedFiles.length === 0 && results.css.selectors.combinedFiles.length === 0 && results.css.selectors.pseudoFiles.length === 0,
      hasIdSelectors: results.css.selectors.simpleIdFiles.length > 0
    },
    keyframes: {
      maxStopCount: Object.values(results.css.keyframes).reduce((max, keyframe) => Math.max(max, keyframe.maxStopCount), 0),
      usesTransform: Object.prototype.hasOwnProperty.call(results.css.properties.keyframes, "transform"),
      usesOpacity: Object.prototype.hasOwnProperty.call(results.css.properties.keyframes, "opacity")
    }
  };
}

function addFeature(target, featureName, enabled, file) {
  if (!target[featureName]) {
    target[featureName] = { files: [] };
  }

  if (enabled && !target[featureName].files.includes(file)) {
    target[featureName].files.push(file);
    target[featureName].files.sort();
  }
}

function getFeatureFiles(target, featureName) {
  return target[featureName] ? [...target[featureName].files] : [];
}

function incrementFileCounter(target, key) {
  target[key] = (target[key] || 0) + 1;
}

function incrementGlobalCounter(target, key, file, amount) {
  if (!target[key]) {
    target[key] = {
      occurrenceCount: 0,
      fileCount: 0,
      files: [],
      perFile: {}
    };
  }

  target[key].occurrenceCount += amount;
  target[key].perFile[file] = (target[key].perFile[file] || 0) + amount;

  if (!target[key].files.includes(file)) {
    target[key].files.push(file);
    target[key].files.sort();
    target[key].fileCount = target[key].files.length;
  }
}

function addFileToFeature(target, key, file) {
  if (!target[key]) {
    target[key] = { files: [] };
  }

  if (!target[key].files.includes(file)) {
    target[key].files.push(file);
    target[key].files.sort();
  }
}

function pickIndexedValue(items, index) {
  return items[index] || items[items.length - 1] || null;
}

function isTimeToken(token) {
  return /^-?\d*\.?\d+m?s$/i.test(token);
}

function isTimingFunction(token) {
  return /^(linear|ease|ease-in|ease-out|ease-in-out|step-start|step-end)$/i.test(token)
    || /^cubic-bezier\(/i.test(token)
    || /^steps\(/i.test(token);
}

function isIterationCount(token) {
  return token === "infinite" || /^-?\d*\.?\d+$/.test(token);
}

function isFillMode(token) {
  return /^(none|forwards|backwards|both)$/i.test(token);
}

function isDirectionToken(token) {
  return /^(normal|reverse|alternate|alternate-reverse)$/i.test(token);
}

function isPlayStateToken(token) {
  return /^(running|paused)$/i.test(token);
}

function buildMarkdown(results) {
  const actualElements = results.summary.actualElements;
  const cssFeatureRows = [
    "style-block",
    "@keyframes",
    "animation-binding",
    "transform-origin",
    "transition",
    "inline-style-attr",
    "style-outside-defs",
    "custom-property",
    "value:var()",
    "value:calc()",
    "animation-delay",
    "animation-longhand",
    "fill-mode:forwards",
    "iteration:infinite",
    "iteration:1",
    "timing:ease-in-out",
    "timing:linear",
    "timing:ease-out",
    "timing:cubic-bezier",
    "timing:steps",
    "transform-box",
    "mix-blend-mode",
    "rule:visibility",
    "keyframes:transform",
    "keyframes:opacity",
    "keyframes:fill",
    "keyframes:stroke-width",
    "keyframes:r",
    "keyframes:width",
    "keyframes:visibility",
    "keyframes:10+ stops",
    "keyframes:15+ stops",
    "selector:.class",
    "selector:#id",
    "selector:combined",
    "selector:pseudo",
    "selector:unsupported",
    "@media",
    "other-at-rule"
  ];

  const lines = [];
  lines.push("# SVG Capability Audit");
  lines.push("");
  lines.push(`扫描时间：${results.generatedAt}`);
  lines.push(`扫描范围：\`${results.svgDirectory}/clawd-*.svg\``);
  lines.push(`文件数：${results.fileCount}`);
  lines.push("");
  lines.push("## 扫描结论");
  lines.push("");
  lines.push(renderSummaryParagraph(results));
  lines.push("");
  lines.push("## Table 1: SVG Element Capability Matrix");
  lines.push("");
  lines.push(renderMatrix("Element", actualElements, results.files, (element, file) => {
    return results.elements[element] && results.elements[element].files.includes(file);
  }));
  lines.push("");
  lines.push("## Table 2: CSS Animation Capability Matrix");
  lines.push("");
  lines.push(renderMatrix("Feature", cssFeatureRows, results.files, (feature, file) => {
    return results.css.features[feature] && results.css.features[feature].files.includes(file);
  }));
  lines.push("");
  lines.push("## 最小实现能力集");
  lines.push("");
  lines.push(renderCapabilitySummary(results));
  lines.push("");
  lines.push("## 风险与边界");
  lines.push("");
  lines.push(renderRiskSection(results));
  lines.push("");
  lines.push("## 关键帧与选择器补充");
  lines.push("");
  lines.push(renderKeyframeSection(results));
  lines.push("");
  lines.push("## 人工交叉检查");
  lines.push("");
  lines.push("_待补充：从 5 个 SVG 人工核对扫描结果。_");
  lines.push("");
  lines.push("## Parser Capability Checklist");
  lines.push("");
  lines.push(renderChecklist(results));
  return lines.join("\n");
}

function renderSummaryParagraph(results) {
  const actualElements = formatCodeList(results.summary.actualElements);
  const unexpectedElements = results.summary.unexpectedElements.length > 0
    ? formatCodeList(results.summary.unexpectedElements)
    : "无";
  const selectorSummary = results.css.selectors.combinedFiles.length === 0
    && results.css.selectors.pseudoFiles.length === 0
    && results.css.selectors.unsupportedFiles.length === 0
    ? "CSS 选择器维持在 `.class` 和 `#id` 范围内"
    : "发现超出 `.class` / `#id` 的选择器";
  const transitionFiles = results.summary.transitionFiles.length > 0
    ? `${results.summary.transitionFiles.length} 个 SVG 使用了 ` + "`transition`"
    : "没有 SVG 使用 `transition`";
  const extraSummary = [];
  if (results.summary.styleOutsideDefsFiles.length > 0) {
    extraSummary.push(`${results.summary.styleOutsideDefsFiles.length} 个 SVG 存在 defs 外的 style`);
  }
  if (results.summary.customPropertyFiles.length > 0) {
    extraSummary.push(`${results.summary.customPropertyFiles.length} 个 SVG 使用 CSS 自定义属性`);
  }

  return `实际用到的 SVG 元素是 ${actualElements}。超出主计划已知子集的元素：${unexpectedElements}。最大关键帧停靠点数量是 ${results.summary.maxKeyframeStopCount}。${selectorSummary}。${transitionFiles}。${extraSummary.join("，") || "未发现额外 CSS 结构风险。"}。`;
}

function renderCapabilitySummary(results) {
  const elements = formatCodeList(results.summary.parserMinimumCapability.elements);
  const properties = formatCodeList(results.summary.parserMinimumCapability.cssProperties);
  const markerParts = Object.entries(results.summary.specialMarkers)
    .map(([marker, files]) => `${marker} ${files.length} 个文件`)
    .join("，");
  const transitionNote = results.summary.transitionFiles.length > 0
    ? `需要保留 \`transition: transform ...\` 的解析入口，覆盖 ${results.summary.transitionFiles.length} 个眼球追踪相关 SVG。`
    : "不需要实现 transition。";
  const longhandNote = results.summary.animationLonghandFiles.length > 0
    ? `另外有 ${results.summary.animationLonghandFiles.length} 个 SVG 使用 animation longhands。`
    : "";

  return `Parser 至少需要支持元素 ${elements}，并处理属性/样式 ${properties}。动画侧必须支持多 stop 的 \`@keyframes\`、嵌套 group 动画叠加、\`transform\` 与 \`opacity\` 同时出现在同一个 keyframes 中。特殊运行时标记覆盖情况是 ${markerParts}。${transitionNote}${longhandNote}`;
}

function renderRiskSection(results) {
  const risks = [];

  if (results.summary.unexpectedElements.length > 0) {
    risks.push(`发现未在主计划列出的元素 ${formatCodeList(results.summary.unexpectedElements)}，Phase 1 需要显式纳入。`);
  }

  if (results.css.features["inline-style-attr"] && results.css.features["inline-style-attr"].files.length > 0) {
    risks.push(`存在内联 \`style\` 属性，文件数为 ${results.css.features["inline-style-attr"].files.length}，解析器不能只看 \`<style>\` 块。`);
  }
  if (results.summary.styleOutsideDefsFiles.length > 0) {
    risks.push(`存在 defs 外的 \`<style>\`，文件为 ${results.summary.styleOutsideDefsFiles.map((file) => `\`${file}\``).join("、")}。`);
  }
  if (results.summary.customPropertyFiles.length > 0) {
    risks.push(`存在 CSS 自定义属性 / \`var()\` / \`calc()\`，文件为 ${results.summary.customPropertyFiles.map((file) => `\`${file}\``).join("、")}，这部分不在原始已知子集内。`);
  }

  if (results.summary.maxKeyframeStopCount >= 15) {
    risks.push(`关键帧停靠点上限达到 ${results.summary.maxKeyframeStopCount}，` +
      "Core Animation 映射时不能假设 keyframe 很短。");
  }

  if (results.css.features["timing:cubic-bezier"] && results.css.features["timing:cubic-bezier"].files.length > 0) {
    risks.push("存在 `cubic-bezier(...)`，TimingFunction 映射不能只支持预设枚举。");
  }

  if (results.css.features["timing:steps"] && results.css.features["timing:steps"].files.length > 0) {
    risks.push("存在 `steps(...)`，如果后续渲染器不支持，需要在 Phase 1 明确降级策略。");
  }
  if (results.summary.transformBoxFiles.length > 0) {
    risks.push(`存在 \`transform-box\`，文件为 ${results.summary.transformBoxFiles.map((file) => `\`${file}\``).join("、")}。`);
  }
  if (results.summary.mixBlendModeFiles.length > 0) {
    risks.push(`存在 \`mix-blend-mode\`，文件为 ${results.summary.mixBlendModeFiles.map((file) => `\`${file}\``).join("、")}。`);
  }

  if (results.css.selectors.combinedFiles.length > 0 || results.css.selectors.pseudoFiles.length > 0 || results.css.selectors.unsupportedFiles.length > 0) {
    risks.push("发现复杂选择器，需要补充选择器解析范围。");
  } else {
    risks.push("没有发现组合选择器、伪类或媒体查询，选择器解析可以收敛在简单 `.class` / `#id`。");
  }

  return risks.map((risk) => `- ${risk}`).join("\n");
}

function renderKeyframeSection(results) {
  const longest = results.summary.maxKeyframeFiles
    .map((entry) => `\`${entry.name}\` 最多 ${entry.maxStopCount} 个停靠点，涉及 ${entry.files.map(shortName).join("、")}`)
    .join("；");
  const propertyUsage = Object.keys(results.css.properties.keyframes)
    .sort()
    .map((property) => `\`${property}\`(${results.css.properties.keyframes[property].fileCount})`)
    .join("，");
  const transformOrigins = Object.entries(results.css.transformOrigins.values)
    .sort((left, right) => right[1].files.length - left[1].files.length || left[0].localeCompare(right[0]))
    .slice(0, 8)
    .map(([value, entry]) => `\`${value}\`(${entry.files.length})`)
    .join("，");

  return `关键帧属性覆盖是 ${propertyUsage}。最长关键帧是 ${longest || "无"}。最常见的 transform-origin 值包括 ${transformOrigins || "无"}。`;
}

function renderChecklist(results) {
  const checklist = [];
  const actualElements = results.summary.actualElements;
  checklist.push(`- 支持元素：${formatCodeList(actualElements)}。`);
  checklist.push(`- 支持属性：${formatCodeList(essentialAttributes(results))}。`);
  checklist.push(`- 支持 CSS 规则：${formatCodeList(results.summary.parserMinimumCapability.cssProperties)}。`);
  checklist.push(`- 支持 \`@keyframes\` 多 stop 解析，当前上限至少按 ${results.summary.maxKeyframeStopCount} 个停靠点设计。`);
  checklist.push(`- 支持简单选择器 \`.class\` 和 \`#id\`。`);
  checklist.push(`- 支持 \`transform\` 函数族：translate / translateX / translateY / scale / scaleX / scaleY / rotate。`);
  checklist.push(`- 支持 \`opacity\` 在普通规则和 keyframes 中同时出现。`);
  checklist.push(`- 支持 \`forwards\` 和延迟启动的 one-shot 动画。`);
  checklist.push(`- 支持嵌套 group 动画叠加。`);
  checklist.push(`- 保留运行时定位 \`#eyes-js\`、\`#body-js\`、\`#shadow-js\`。`);

  if (results.summary.unexpectedElements.length > 0) {
    checklist.push(`- 额外纳入未预期元素：${formatCodeList(results.summary.unexpectedElements)}。`);
  }
  if (results.summary.customPropertyFiles.length > 0) {
    checklist.push(`- 处理 CSS 自定义属性和 \`var()\`/ \`calc()\`，至少覆盖 ${results.summary.customPropertyFiles.map((file) => `\`${file}\``).join("、")}。`);
  }
  if (results.summary.styleOutsideDefsFiles.length > 0) {
    checklist.push("- 支持扫描 defs 外的 `<style>`。");
  }
  if (results.summary.transformBoxFiles.length > 0) {
    checklist.push(`- 评估并处理 \`transform-box\`，当前涉及 ${results.summary.transformBoxFiles.map((file) => `\`${file}\``).join("、")}。`);
  }
  if (results.summary.mixBlendModeFiles.length > 0) {
    checklist.push(`- 评估 \`mix-blend-mode\`，当前涉及 ${results.summary.mixBlendModeFiles.map((file) => `\`${file}\``).join("、")}。`);
  }

  if (results.css.selectors.combinedFiles.length === 0 && results.css.selectors.pseudoFiles.length === 0 && results.css.selectors.unsupportedFiles.length === 0) {
    checklist.push("- 不需要实现组合选择器、伪类、媒体查询。");
  }

  return checklist.join("\n");
}

function renderMatrix(label, rows, files, predicate) {
  const header = [label, ...files.map(shortName)];
  const divider = header.map(() => "---");
  const lines = [
    `| ${header.join(" | ")} |`,
    `| ${divider.join(" | ")} |`
  ];

  for (const row of rows) {
    const cells = [row, ...files.map((file) => predicate(row, file) ? "✓" : "✗")];
    lines.push(`| ${cells.join(" | ")} |`);
  }

  return lines.join("\n");
}

function shortName(file) {
  return file.replace(/^clawd-/, "").replace(/\.svg$/i, "");
}

function formatCodeList(items) {
  return items.map((item) => `\`${item}\``).join("、");
}

function essentialAttributes(results) {
  const preferredOrder = [
    "viewBox",
    "width",
    "height",
    "xmlns",
    "id",
    "class",
    "x",
    "y",
    "width",
    "height",
    "fill",
    "opacity",
    "href",
    "transform",
    "style"
  ];
  const actualAttributes = new Set(Object.keys(results.attributes));
  const ordered = [];

  for (const attribute of preferredOrder) {
    if (actualAttributes.has(attribute) && !ordered.includes(attribute)) {
      ordered.push(attribute);
    }
  }

  for (const attribute of Array.from(actualAttributes).sort()) {
    if (!ordered.includes(attribute)) {
      ordered.push(attribute);
    }
  }

  return ordered;
}

main();
