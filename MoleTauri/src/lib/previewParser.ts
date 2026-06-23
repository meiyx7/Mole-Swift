// 解析 mo clean --dry-run / mo optimize --dry-run 的流式输出
// 参考 MoleApp/Core/PreviewParser.swift 的解析逻辑

import { StreamingLine } from './cli';

export interface PreviewEntry {
  path: string;
  description: string;
  sizeBytes: number;
  sizeText: string;
  kind: 'wouldClean' | 'nothing' | 'skipped' | 'orphan' | 'info';
  risk: 'LOW' | 'MEDIUM' | 'HIGH';
}

export interface PreviewSection {
  name: string;
  entries: PreviewEntry[];
  totalSize: number;
  hasContent: boolean;
}

export interface PreviewSummary {
  totalSize: number;
  totalSizeText: string;
  items: number;
  categories: number;
  freedSpace?: string;
  freeSpaceNow?: string;
  freeSpaceChange?: string;
}

export interface ParseResult {
  sections: PreviewSection[];
  summary: PreviewSummary | null;
  rawLines: StreamingLine[];
}

// 解析大小文本（如 "1.23GB", "456MB", "78.9KB"）为字节数
function parseSize(text: string): number {
  const m = text.match(/([\d.]+)\s*(GB|MB|KB|B|TB)/i);
  if (!m) return 0;
  const val = parseFloat(m[1]);
  const unit = m[2].toUpperCase();
  const mult: Record<string, number> = {
    B: 1,
    KB: 1024,
    MB: 1024 * 1024,
    GB: 1024 * 1024 * 1024,
    TB: 1024 * 1024 * 1024 * 1024,
  };
  return Math.round(val * (mult[unit] || 1));
}

// 风险分级（参考 bin/clean.sh classify_cleanup_risk）
function classifyRisk(description: string, path: string): 'LOW' | 'MEDIUM' | 'HIGH' {
  if (/system|sudo|\/System|\/Library/i.test(description + path)) return 'HIGH';
  if (/preference|\/Preferences\//i.test(description + path)) return 'HIGH';
  if (/installer|app.*bundle|large/i.test(description)) return 'MEDIUM';
  if (/backup|download|orphan/i.test(description)) return 'MEDIUM';
  if (/cache|log|temp|thumbnail/i.test(description)) return 'LOW';
  return 'MEDIUM';
}

// 剥离 ANSI 颜色码
function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, '');
}

export function parsePreviewLine(raw: string): { section?: string; entry?: PreviewEntry; summary?: PreviewSummary; raw: string } {
  const line = stripAnsi(raw).trimEnd();
  if (!line) return { raw };

  // Section 头：➤ Section 或 ━━━ Section ━━━
  const sectionMatch = line.match(/(?:➤|▸|▶|━+)\s*(.+?)(?:\s*━+)?$/);
  if (sectionMatch && (line.includes('➤') || line.includes('━'))) {
    const name = sectionMatch[1].trim();
    if (name && !name.includes(',')) {
      return { section: name, raw: line };
    }
  }

  // dry-run 项：  ◇ label, SIZE dry  或  → item, SIZE dry
  const dryMatch = line.match(/^\s*[◇→◎]\s*(.+?),\s*([\d.]+\s*[GMK]?B)\s*dry/i);
  if (dryMatch) {
    const desc = dryMatch[1].trim();
    const sizeText = dryMatch[2];
    const sizeBytes = parseSize(sizeText);
    // 尝试提取路径（可能在描述中或后续行）
    const pathMatch = desc.match(/(\/\S+)/);
    return {
      entry: {
        path: pathMatch ? pathMatch[1] : desc,
        description: desc,
        sizeBytes,
        sizeText,
        kind: 'wouldClean',
        risk: classifyRisk(desc, pathMatch ? pathMatch[1] : ''),
      },
      raw: line,
    };
  }

  // 实际删除：  ✓ label, SIZE
  const cleanMatch = line.match(/^\s*✓\s*(.+?),\s*([\d.]+\s*[GMK]?B)/i);
  if (cleanMatch) {
    const desc = cleanMatch[1].trim();
    const sizeText = cleanMatch[2];
    const sizeBytes = parseSize(sizeText);
    const pathMatch = desc.match(/(\/\S+)/);
    return {
      entry: {
        path: pathMatch ? pathMatch[1] : desc,
        description: desc,
        sizeBytes,
        sizeText,
        kind: 'wouldClean',
        risk: classifyRisk(desc, pathMatch ? pathMatch[1] : ''),
      },
      raw: line,
    };
  }

  // Nothing to clean
  if (/nothing to clean|无需清理/i.test(line)) {
    return {
      entry: {
        path: '',
        description: 'Nothing to clean',
        sizeBytes: 0,
        sizeText: '0 B',
        kind: 'nothing',
        risk: 'LOW',
      },
      raw: line,
    };
  }

  // Skipped
  const skipMatch = line.match(/^\s*[◎•]\s*[Ss]kipped:?\s*(.+)/);
  if (skipMatch) {
    return {
      entry: {
        path: skipMatch[1].trim(),
        description: 'Skipped',
        sizeBytes: 0,
        sizeText: '',
        kind: 'skipped',
        risk: 'LOW',
      },
      raw: line,
    };
  }

  // Potential orphan
  const orphanMatch = line.match(/^\s*•\s*[Pp]otential orphan:?\s*(.+)/);
  if (orphanMatch) {
    return {
      entry: {
        path: orphanMatch[1].trim(),
        description: 'Potential orphan',
        sizeBytes: 0,
        sizeText: '',
        kind: 'orphan',
        risk: 'MEDIUM',
      },
      raw: line,
    };
  }

  // 汇总行：Potential space: X | Items: N | Categories: M
  const summaryMatch = line.match(/(?:Potential space|Tracked cleanup|可回收空间|已释放空间):\s*([\d.]+\s*[GMK]?B)/i);
  if (summaryMatch) {
    const sizeText = summaryMatch[1];
    const sizeBytes = parseSize(sizeText);
    const itemsMatch = line.match(/[Ii]tems?[:\s]+(\d+)/);
    const catsMatch = line.match(/[Cc]ategories?[:\s]+(\d+)/);
    return {
      summary: {
        totalSize: sizeBytes,
        totalSizeText: sizeText,
        items: itemsMatch ? parseInt(itemsMatch[1]) : 0,
        categories: catsMatch ? parseInt(catsMatch[1]) : 0,
      },
      raw: line,
    };
  }

  // Free space 行
  const freeMatch = line.match(/[Ff]ree space\s*(?:now|change)?:\s*(.+)/);
  if (freeMatch) {
    const val = freeMatch[1].trim();
    if (/change/i.test(line)) {
      return { summary: { totalSize: 0, totalSizeText: '', items: 0, categories: 0, freeSpaceChange: val }, raw: line };
    }
    return { summary: { totalSize: 0, totalSizeText: '', items: 0, categories: 0, freeSpaceNow: val }, raw: line };
  }

  return { raw: line };
}

// 增量解析器：逐行喂入，维护 sections 状态
export class PreviewParser {
  sections: PreviewSection[] = [];
  currentSection: PreviewSection | null = null;
  summary: PreviewSummary | null = null;
  rawLines: StreamingLine[] = [];

  feed(line: StreamingLine) {
    this.rawLines.push(line);
    const parsed = parsePreviewLine(line.text);

    if (parsed.section) {
      this.currentSection = {
        name: parsed.section,
        entries: [],
        totalSize: 0,
        hasContent: false,
      };
      this.sections.push(this.currentSection);
      return;
    }

    if (parsed.entry && this.currentSection) {
      this.currentSection.entries.push(parsed.entry);
      if (parsed.entry.kind === 'wouldClean') {
        this.currentSection.totalSize += parsed.entry.sizeBytes;
        this.currentSection.hasContent = true;
      }
      return;
    }

    if (parsed.summary) {
      if (!this.summary) {
        this.summary = parsed.summary;
      } else {
        // 合并后续的 summary 行（如 free space）
        if (parsed.summary.freeSpaceNow) this.summary.freeSpaceNow = parsed.summary.freeSpaceNow;
        if (parsed.summary.freeSpaceChange) this.summary.freeSpaceChange = parsed.summary.freeSpaceChange;
        if (parsed.summary.totalSize > 0) {
          this.summary.totalSize = parsed.summary.totalSize;
          this.summary.totalSizeText = parsed.summary.totalSizeText;
        }
        if (parsed.summary.items > 0) this.summary.items = parsed.summary.items;
        if (parsed.summary.categories > 0) this.summary.categories = parsed.summary.categories;
      }
      return;
    }
  }

  getResult(): ParseResult {
    return {
      sections: this.sections,
      summary: this.summary,
      rawLines: this.rawLines,
    };
  }

  reset() {
    this.sections = [];
    this.currentSection = null;
    this.summary = null;
    this.rawLines = [];
  }
}
