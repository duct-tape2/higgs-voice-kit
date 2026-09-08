#!/usr/bin/env python3
"""
Sentence-aware text chunker for higgs-voice-kit.

Splits text into sentences based on punctuation (. ! ?), then packs
whole sentences into chunks of at most HIGGS_CHUNK characters.

A single sentence longer than the limit is split at the last comma/space.
Never loses or reorders text.

Usage:
  python3 chunk_text.py <text_file_or_string> [chunk_size]

Returns: one chunk per line
"""

import sys
import re


def split_into_sentences(text):
    """
    Split text into sentences at punctuation marks (. ! ?) and newlines.
    Handles both Korean and English text.
    """
    sentences = []

    # Split on sentence-ending punctuation (. ! ?)
    # Pattern: punctuation possibly followed by closing quotes/brackets
    parts = re.split(r'[.!?]+', text)

    # Find all the punctuation marks that were split on
    matches = re.findall(r'[.!?]+', text)

    # Reconstruct sentences with their punctuation
    for i, part in enumerate(parts):
        part = part.strip()
        if not part:
            continue

        # Add back the punctuation (if there was one)
        if i < len(matches):
            sent = part + matches[i]
        else:
            sent = part

        sentences.append(sent)

    return [s for s in sentences if s.strip()]


def split_sentence_at_boundary(text, max_len):
    """
    Split a sentence that's longer than max_len at the last comma or space.
    """
    if len(text) <= max_len:
        return [text]

    result = []
    while len(text) > max_len:
        # Find last comma or space before max_len
        split_pos = max_len
        for i in range(max_len - 1, -1, -1):
            if text[i] in ', \t':
                split_pos = i + 1
                break

        result.append(text[:split_pos].strip())
        text = text[split_pos:].strip()

    if text:
        result.append(text)

    return result


def pack_into_chunks(sentences, chunk_size):
    """
    Pack sentences into chunks of at most chunk_size characters.
    A single sentence longer than chunk_size is split at the last comma/space.
    """
    chunks = []
    current_chunk = []
    current_length = 0

    for sentence in sentences:
        sent_len = len(sentence)

        # If sentence is longer than chunk_size, split it
        if sent_len > chunk_size:
            # Flush current chunk if non-empty
            if current_chunk:
                chunks.append(' '.join(current_chunk))
                current_chunk = []
                current_length = 0

            # Split the long sentence
            parts = split_sentence_at_boundary(sentence, chunk_size)
            for part in parts:
                if len(part) <= chunk_size:
                    chunks.append(part)
                else:
                    # This shouldn't happen, but handle gracefully
                    chunks.append(part)
        else:
            # Try to fit into current chunk
            test_len = current_length + sent_len + (1 if current_chunk else 0)

            if test_len <= chunk_size:
                current_chunk.append(sentence)
                current_length = test_len
            else:
                # Flush current chunk and start new one
                if current_chunk:
                    chunks.append(' '.join(current_chunk))
                current_chunk = [sentence]
                current_length = sent_len

    # Flush remaining
    if current_chunk:
        chunks.append(' '.join(current_chunk))

    return [c for c in chunks if c.strip()]


def validate_chunks(text, chunks):
    """
    Assert that concatenated chunks (ignoring whitespace) equals original.
    """
    orig_normalized = re.sub(r'\s+', '', text)
    chunks_normalized = re.sub(r'\s+', '', ' '.join(chunks))
    if orig_normalized != chunks_normalized:
        print('ERROR: chunk concatenation mismatch', file=sys.stderr)
        print(f'  Original: {len(orig_normalized)} chars', file=sys.stderr)
        print(f'  Chunks:   {len(chunks_normalized)} chars', file=sys.stderr)
        # Show first diff position
        for i, (a, b) in enumerate(zip(orig_normalized, chunks_normalized)):
            if a != b:
                print(f'  First diff at pos {i}: got {repr(b)}, expected {repr(a)}', file=sys.stderr)
                break
        return False
    return True


def main():
    # Windows defaults to the ANSI code page; force UTF-8 so Korean text survives the pipe.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8')
        except Exception:
            pass
    if len(sys.argv) < 2:
        print('Usage: chunk_text.py <text_file_or_string> [chunk_size]', file=sys.stderr)
        sys.exit(1)

    text_input = sys.argv[1]
    chunk_size = int(sys.argv[2]) if len(sys.argv) > 2 else 200

    # Try to read as file first
    try:
        with open(text_input, 'r', encoding='utf-8') as f:
            text = f.read()
    except (FileNotFoundError, IsADirectoryError, PermissionError):
        # Treat as literal text
        text = text_input

    # Remove comments and normalize whitespace (keep paragraph structure initially)
    lines = text.split('\n')
    cleaned_lines = [
        re.sub(r'^\s*#.*$', '', line) for line in lines
    ]
    text = '\n'.join(cleaned_lines)
    # Normalize multiple spaces but keep paragraph breaks
    text = re.sub(r'[ \t]+', ' ', text)
    # Convert newlines to spaces (flatten paragraphs)
    text = re.sub(r'\s*\n\s*', ' ', text)
    text = text.strip()

    if not text:
        print('No text to process', file=sys.stderr)
        sys.exit(1)

    sentences = split_into_sentences(text)
    chunks = pack_into_chunks(sentences, chunk_size)

    if not validate_chunks(text, chunks):
        sys.exit(1)

    # Output one chunk per line
    for chunk in chunks:
        print(chunk)


if __name__ == '__main__':
    main()
