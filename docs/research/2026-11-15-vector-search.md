# Search by meaning: vector embeddings and sqlite-vector

Date: 2026-11-15
Status: research only. No source in this repository was changed, no dependency was added, the app was not launched and the library database was not opened. Four scratch checks were run outside the repository, on made-up strings only, and deleted afterwards; each is described where its result is used.

## 1. Summary and recommendation

The owner asked to "research improving search for best match with vector embeddings", pointing at https://github.com/sqliteai/sqlite-vector.

**Short answer: do not add embeddings or sqlite-vector for channel search, and do not add sqlite-vector at all at this library's size. Spend the effort on three small lexical changes. Run one cheap experiment before deciding anything about search by meaning over programmes.**

1. **Channel names are the wrong input for embeddings.** "NBC", "ESPN2" and "KNSD" are identifiers, not sentences. Apple's built-in sentence embedding, tried here on made-up names, ranked "NBA TV" above "USA: KNSD (NBC)" for the query "NBC", and "HGTV" above the KNSD channel for the query "KNSD" (5.2). The lexical ranking that was just shipped gets these right by construction.
2. **For programmes, search by meaning is a real feature ("basketball" finding an NBA game whose title never says basketball), but Apple's built-in embeddings did not deliver it in a toy test** (5.3). A proper sentence model (all-MiniLM-L6-v2 through Core ML) probably would, at the cost of a 23 to 91 MB model in the bundle, a tokenizer, and minutes of extra CPU on each guide import. That it would is **[not verified]**.
3. **sqlite-vector is not needed and is awkward to load.** Its licence is no longer an obstacle (Apache 2.0 since 2026-09-10; section 2.6). But the system SQLite that GRDB uses is built without extension loading, so the vendor's prebuilt binary cannot be loaded at all; the only route is compiling its 10,500 lines of C into the app (section 3). And at 72,000 rows it buys nothing: a plain Accelerate dot product over 72,000 × 512 floats took 0.7 ms on this Mac (4.5).
4. **What does address the owner's actual complaints**, in order of value for effort (section 6): typo tolerance for channel names by edit distance in Swift, used only when the lexical search comes back thin; a small alias table (network ↔ call sign, "espn 2" ↔ "espn2"); and `bm25()` column weights for programmes.
5. **The experiment** (section 7.2): a test-only harness that embeds programme titles from a fixture, runs twenty or thirty queries the owner actually types, and compares lexical, vector and fused rankings side by side. Half a day, nothing shipped. Embeddings go in only if they win there.

### How claims are marked

- A URL or `file:line` after a statement means it was read there for this note.
- **[checked here]** means established by a command run for this note.
- **[measured here]** means timed on this machine (Apple M5 Pro, macOS 27.2.1) in a scratch program outside the repository, on synthetic strings.
- **[inferred]** means reasoned from sources and the code, not stated by either.
- **[general knowledge]** means not read in a source for this note.
- **[not verified]** means it was not established; section 8 collects these.

## 2. sqlite-vector

### 2.1 What it is

A SQLite extension in C from SQLite Cloud, Inc. (the company behind sqlite.ai) that scans vectors stored as ordinary BLOB columns. From its README (https://github.com/sqliteai/sqlite-vector/blob/main/README.md): "No virtual tables required – store vectors directly as `BLOB`s in ordinary tables", "Zero preindexing needed", and "defaults to just 30MB of RAM usage".

It has no approximate index (no HNSW, IVF or DiskANN); the README says so and presents it as a feature. Every query is a linear scan, either over the raw vectors or over a quantized copy. "ANN" in its documents means the quantized scan.

### 2.2 API

From https://github.com/sqliteai/sqlite-vector/blob/main/API.md:

- **Storage.** A BLOB column in any rowid table. Element types: `FLOAT32` (default), `FLOAT16`, `FLOATB16`, `INT8`, `UINT8`, `1BIT`. `vector_as_f32()` and its siblings convert a JSON array to the BLOB form; a BLOB passed in is taken as is.
- **`vector_init(table, column, 'dimension=384,type=FLOAT32,distance=COSINE')`**. "Mandatory before performing any vector search", and "must be called in every database connection that needs to perform vector operations". Distances: `L2` (default), `SQUARED_L2`, `COSINE`, `DOT`, `L1`, and `HAMMING` for 1-bit vectors only. `normalized=1` asserts unit-length vectors and makes cosine a single dot product.
- **`vector_full_scan(table, column, vector [, k])`**. A table-valued function returning `(rowid, distance)`: exact brute force, described as "useful for small datasets (rows < 1000000)". No build step at all.
- **`vector_quantize(table, column, 'qtype=INT8')`**, then **`vector_quantize_scan(...)`**. Quantizing builds a compact copy that the scan reads instead of the raw vectors. "You must run `vector_quantize()` before using `vector_quantize_scan()` and when data initialized for vectors changes." Quantization types: `UINT8`, `INT8`, `1BIT`, and TurboQuant at 2, 3 or 4 bits per dimension.
- **`vector_quantize_preload(table, column)`** holds the quantized copy in process memory; "the preloaded data is also shared across all database connections". `vector_quantize_memory()` reports the size, `vector_quantize_cleanup()` drops it.
- Without `k`, both scans stream rows so that SQL `WHERE` and `LIMIT` apply.

**So is there an index build?** Not for exact search. For the quantized scan there is a rebuild after every change to the data, which here means after every guide import. **[inferred from the API text above]**

### 2.3 Performance and memory claims

All from the README's benchmark, on an Apple M5 Pro with NEON, 1,000,000 vectors of dimension 768, cosine, k = 20, uniform random data, database in a file:

| Mode | Index size | ms per query | Recall@20 |
| --- | ---: | ---: | ---: |
| `FLOAT32` exact | 2930 MB | 484.4 | 100% |
| `INT8` preloaded | 740 MB | 37.6 | 99.5% |
| `INT8` streamed (30 MB cap) | 740 MB | 114.4 | 99.5% |
| `1BIT` | 99 MB | 2.5 | 10.0% |
| `TURBO4` | 378 MB | 151.5 | 81.8% |

The README is candid that random data is the worst case for recall, that `UINT8` is wrong for cosine (33.8% recall), and that the timings are best of 20 with the file in the page cache. These are the vendor's numbers; none was reproduced here.

Scaled to this library (72,000 × 512), the `INT8` preloaded scan would be about 37.6 × 0.072 × (512 ÷ 768) ≈ 1.8 ms. **[inferred by linear scaling; not measured]** Section 4.5 shows the plain Accelerate equivalent is already under a millisecond.

### 2.4 Platforms and how it ships for the Mac

- Release 1.2.0 (2026-11-01) carries, among others, `vector-macos-arm64-1.2.0.tar.gz` (67 KB, a loadable `.dylib`), a universal `vector-macos-1.2.0`, and `vector-apple-xcframework-1.2.0.zip` (380 KB) **[checked here: GitHub releases API]**.
- The repository is also a Swift package: `Package.swift` declares a binary target at that xcframework's URL plus a one-file Swift target whose only content is `vector.path`, the path of the framework binary inside the app bundle, "for use with sqlite3_load_extension" (https://github.com/sqliteai/sqlite-vector/blob/main/Package.swift, https://github.com/sqliteai/sqlite-vector/blob/main/packages/swift/vector.swift). Platforms: macOS 11, iOS 12.
- The xcframework has three slices: `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`. The Mac framework binary is 404 KB universal, signed "Developer ID Application: SQLabs srl (3ZH6236ET5)" with the hardened-runtime flag, and its only dependency is `libSystem` **[checked here: archive listing, `otool -L`, `codesign -dvv`; SHA-256 matched the one in `Package.swift`]**.
- **The prebuilt binary has no undefined `sqlite3_*` symbols** **[checked here: `nm -u`]**. It is a true loadable extension: it reaches SQLite only through the routine table that `sqlite3_load_extension` hands it. Section 3 shows why that matters.
- The vendor's own instruction for Apple platforms is to bring a second copy of SQLite: "You need a version of SQLite that supports loading extensions", then "Download SQLite Amalgamation (Recommended)" (https://github.com/sqliteai/sqlite-extensions-guide/blob/main/platforms/ios.md, step 4; the macOS page points to the same route).

### 2.5 Version and maturity

- Repository created 2025-04-07; 1.0.0 on 2026-05-25; 1.2.0 on 2026-11-01; about 1,200 stars; 63 issues and pull requests in total, 3 open **[checked here: GitHub API]**.
- The 1.2.0 changelog, two weeks old: "A read-through of the sources, followed by a security review of all of `src/`, turned up ten bugs. Three of them write outside their buffers and are reachable from ordinary SQL" (https://github.com/sqliteai/sqlite-vector/blob/main/CHANGELOG.md). One of the ten: after a failed `vector_quantize()`, "Scans then read the chunks at the wrong stride and reported made-up rowids and distances with no error at all."
- That is honest reporting and the bugs are fixed, but it describes a young C code base whose memory safety was first reviewed this month. Against the standing goal of rock-solid stability, that is a cost. **[inferred]**
- The source is `src/sqlite-vector.c` (172 KB) plus one distance file per SIMD family; 10,572 lines of C in `src/` at tag 1.2.0 **[checked here: `wc -l`]**. It keeps process-wide state (the preloaded index, guarded by SQLite's `SQLITE_MUTEX_STATIC_APP1`) and creates a table named `_sqliteai_vector` in the database on first initialisation (`src/sqlite-vector.c:129`, `:3964-3976`).

### 2.6 Licence, precisely

**Today: Apache License 2.0, unmodified.** `LICENSE.md` on `main` and at tags `1.2.0` and `1.1.2` is the standard Apache 2.0 text ending "Copyright 2026 - SQLite Cloud, Inc." **[checked here: the file was read in full on `main`; first line confirmed at both tags]**. GitHub reports `Apache-2.0`, and the README says "This project is licensed under the Apache License 2.0". There is no `NOTICE` file in the tree **[checked here: tree listing at 1.2.0]**.

**Before 2026-09-10: a different licence.** Up to and including release 1.1.0 (2026-08-24), `LICENSE.md` read "Elastic License 2.0 (modified for open-source use)", with an "Additional Grant for Open-Source Projects" and the condition "For non–open-source or commercial production use, you may use, copy, distribute, and prepare derivative works of the software only with a commercial license from SQLite Cloud, Inc." **[checked here: `LICENSE.md` at commit `d6a061a`, the last before two "Update LICENSE.md" commits on 2026-09-10]**. Much of what is written about this project online describes that older licence. **Only 1.1.2 and later are Apache 2.0; an older pinned version would carry the older terms.**

**What Apache 2.0 allows an MIT-licensed app that ships the binary.** Section 2 grants "a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form." Section 3 adds a patent licence, which ends for anyone who sues over the Work. Tuner's own code stays MIT; the two licences are compatible in this direction **[general knowledge]**.

**The conditions**, from section 4, "provided that You meet the following conditions":

- "(a) You must give any other recipients of the Work or Derivative Works a copy of this License". The Apache 2.0 text must ship in the bundle, the way `LICENSES/LGPL-2.1.txt` does for VLCKit (`scripts/bundle.sh:21`).
- "(b) You must cause any modified files to carry prominent notices stating that You changed the files". Applies only if the source is patched.
- "(c) You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work". Applies if the source is vendored into this repository, which is the only workable way to load it (section 3).
- "(d) If the Work includes a "NOTICE" text file ..." There is none, so nothing follows from it today.
- Section 6: no right to the licensor's trade names or marks beyond describing origin.

In practice: add an entry to `THIRD-PARTY-NOTICES.md`, ship `LICENSES/Apache-2.0.txt`, keep the file headers. No fee, no source-publication duty, no field-of-use limit. **The licence is not a reason to avoid sqlite-vector.**

Two smaller points. The source includes three headers under `libs/fp16/` with no licence file beside them **[checked here]**; FP16 is an MIT-licensed library by Marat Dukhan **[general knowledge]**, and its notice would need to be confirmed and carried too. And a licence that changed once can change again for future versions; versions already released under Apache 2.0 stay under it **[general knowledge]**.

## 3. Loading it from GRDB in this project

**What the project uses.** `Package.swift` asks for GRDB `from: "7.0.0"`; `Package.resolved` pins 7.12.0. `Store` opens a `DatabasePool` with a `Configuration` and a `prepareDatabase` block (`Sources/TunerCore/Store/Store.swift:13-24`).

**GRDB on macOS uses the system SQLite.** GRDB's package declares `GRDBSQLite` as a `.systemLibrary` target (`.build/checkouts/GRDB.swift/Package.swift`), and its documentation says "By default, GRDB uses the version of SQLite that ships with the target operating system" (https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md). On this Mac that is `/usr/lib/libsqlite3.dylib`, version 3.54.0 **[checked here]**.

**The system SQLite cannot load extensions.** **[checked here, three ways]**

- A C program linked to `/usr/lib/libsqlite3.dylib` reports `sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 1`, and `SELECT load_extension('x')` fails with "no such function: load_extension".
- The SDK header never declares `sqlite3_load_extension` or `sqlite3_enable_load_extension`; it defines `SQLITE_OMIT_LOAD_EXTENSION` itself (`usr/include/sqlite3.h:11126-11127`).
- The SDK's `libsqlite3.tbd` exports neither symbol.

So the README's `sqlite3_load_extension(db, vector.path, ...)` example does not compile against the system SQLite, and GRDB 7.12.0 has no extension-loading API of its own **[checked here: no `load_extension` call anywhere in GRDB's sources]**.

**Static registration of the prebuilt binary does not work either.** `sqlite3_auto_extension` is exported by the system library **[checked here: `libsqlite3.tbd`]**, but in a build with `SQLITE_OMIT_LOAD_EXTENSION` SQLite passes the entry point a null routine table: `const sqlite3_api_routines *pThunk = 0;` (https://github.com/sqlite/sqlite/blob/master/src/loadext.c, lines 934-935). The vendor's binary reaches every SQLite function through that table (2.4), so calling its `sqlite3_vector_init` on a system connection, directly or through auto-extension, would dereference null. **[inferred from the two facts; not run]** The SwiftPM binary target is therefore unusable with the system SQLite.

**What would work: compile the source into the app.** The source supports it. `sqlite-vector.h` includes plain `sqlite3.h` instead of `sqlite3ext.h` when `SQLITE_CORE` is defined, and the init function skips `SQLITE_EXTENSION_INIT2` (`src/sqlite-vector.h:11-15`, `src/sqlite-vector.c:3964-3967`). As a check, the 1.2.0 sources were compiled for arm64 with `-DSQLITE_CORE` against the macOS SDK's SQLite: they built without errors into a 178 KB library whose 46 `sqlite3_*` references all resolved against `/usr/lib/libsqlite3.dylib` **[checked here: compiled and linked in a scratch directory; the result was not executed]**. In this package that would be a new C target holding a vendored copy of `src/` and the `fp16` headers, with `SQLITE_CORE` defined, and one call in the existing `prepareDatabase` block: `sqlite3_vector_init(db.sqliteConnection, nil, nil)`, followed by `vector_init(...)` on each connection. GRDB documents `db.sqliteConnection` for exactly this kind of raw access (https://github.com/groue/GRDB.swift/blob/master/README.md, "Raw SQLite Pointers").

Open points with that route, all **[not verified]**: that it runs correctly on GRDB's read-only reader connections (init executes `CREATE TABLE IF NOT EXISTS _sqliteai_vector`, harmless only if the writer made the table first); that its process-wide state behaves under a `DatabasePool`'s concurrent readers; and that it works on SQLite 3.54 as Apple builds it.

**GRDB's custom SQLite build is not available here.** GRDB can be built with its own SQLite (3.47.2, older than the system's 3.54.0), but: "The technique described here is not compatible with the Swift Package Manager (SPM)" (same `CustomSQLiteBuilds.md`). This project is SwiftPM only.

**Code signing.** `scripts/bundle.sh:31` signs with `codesign --force --deep -s -`: ad hoc, without `--options runtime`, so the hardened runtime is off and library validation does not apply. Apple: "The Hardened Runtime enables library validation by default. This security-hardening feature prevents a program from loading frameworks, plug-ins, or libraries unless they're either signed by Apple or signed with the same Team ID as the main executable" (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation). Compiled-in C is part of the main executable and raises no signing question under either regime. An embedded third-party framework would be re-signed by `--deep`, as VLCKit already is; if the app is ever signed with a Developer ID and the hardened runtime, re-signing embedded frameworks with the same identity satisfies library validation without the entitlement **[inferred]**.

## 4. Where the embeddings would come from, on the Mac

Nothing below needs the network at query or import time, and nothing leaves the machine.

### 4.1 Apple NaturalLanguage: `NLEmbedding` sentence embeddings

- `NLEmbedding.sentenceEmbedding(for:)`, macOS 11+, returns "An NLEmbedding if available, otherwise nil" (https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:)).
- **Dimension 512 for English** **[measured here]**. Spanish and Italian returned 640-dimension embeddings; French, German, Portuguese, Dutch, Russian, Arabic, Hindi, Turkish, Japanese and Simplified Chinese returned `nil` on this Mac **[measured here; whether those are downloadable on demand or simply absent is not verified]**. Each language is a separate vector space, so a Spanish title and an English query cannot be compared.
- **Speed, one thread** **[measured here]**: 1.0 ms for a one-word query; 1.9 ms per short title (2 to 7 words); 8.7 ms per description-length string (25 to 40 words).
- **Threading.** "A single NLEmbedding instance isn't safe for concurrent use ... calling them on one instance from multiple threads or tasks at the same time can crash your app. Serialize access to a shared instance, or give each thread or task its own instance" (https://developer.apple.com/documentation/naturallanguage/nlembedding).
- Bundle cost: none. The model belongs to the OS.
- Apple does not document the model, its training, or its stability across OS releases. `revision` was 1 here. A new revision in a future macOS would silently invalidate stored vectors unless the revision is stored and checked. **[inferred]**

### 4.2 Apple NaturalLanguage: `NLContextualEmbedding`

- macOS 14+. "A model that computes sequences of embedding vectors for natural language utterances." Assets may need downloading: "Call requestAssets(completionHandler:) before computing the embedding to confirm assets are available" (https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding).
- On this Mac the English (Latin-script) model reported dimension 512, maximum sequence length 256, 20 languages, and `hasAvailableAssets == true`, so no download was requested **[measured here]**. Load took 0.5 s; one string took 6.8 to 8.2 ms; the process peaked at 93 MB.
- It yields one vector per token, not per sentence; a sentence vector has to be made by averaging. Apple's own page steers elsewhere: for semantic similarity it recommends `NLEmbedding` (same page, as summarised when read). Averaged vectors ranked badly in the toy test (5.3).

### 4.3 Core ML with a small sentence transformer

- **all-MiniLM-L6-v2**: Apache 2.0, 384 dimensions, 22.7M parameters, English, "By default, input text longer than 256 word pieces is truncated", trained on over a billion sentence pairs, described as "a sentence and short paragraph encoder" (https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2).
- **Size**: `model.safetensors` is 90.9 MB; the published 8-bit ONNX variant is 23.0 MB; `tokenizer.json` 0.47 MB, `vocab.txt` 0.23 MB **[checked here: Hugging Face file listing]**. A Core ML conversion would land between about 23 MB (8-bit weights) and 91 MB (float32), 45 MB at float16 **[inferred from the parameter count; no conversion was done]**. For scale: VLCKit is already the bulk of the bundle.
- **Bundling**: a compiled `.mlmodelc` directory copied into `Contents/Resources` by `scripts/bundle.sh`, loaded with `MLModel`. Converting it is a one-time developer step with Python `coremltools`, outside the app's build. No hosted Core ML build from the model's authors was found; third-party conversions exist and would need their own vetting **[not verified]**.
- **Tokenizer**: the model needs BERT WordPiece tokenisation (lower-casing, the 30,522-entry vocabulary, `[CLS]`/`[SEP]`, attention mask), then mean pooling and normalisation. Either a few hundred lines of Swift written here, or the `swift-transformers` package (Apache 2.0, https://github.com/huggingface/swift-transformers), which is a second dependency **[licence checked here; the rest general knowledge]**.
- **Multilingual**: all-MiniLM-L6-v2 is English only. A multilingual model of the same output size, `intfloat/multilingual-e5-small` (MIT, 384 dimensions), has 117.7M parameters, about five times the weights, and a SentencePiece tokenizer instead of WordPiece **[parameters and licence checked here: Hugging Face API; tokenizer general knowledge]**.
- **Speed**: not measured. A 6-layer MiniLM on short inputs on Apple silicon is commonly reported in the low single-digit milliseconds per string **[general knowledge; not verified]**.

### 4.4 The same vendor's sqlite-ai

Apache 2.0 **[checked here: GitHub API and `LICENSE`]**. It embeds llama.cpp and Whisper to run GGUF models from SQL: `llm_model_load('./models/nomic-embed-text-v1.5-Q8_0.gguf', ...)`, then `llm_embed_generate('Hello world')` (https://github.com/sqliteai/sqlite-ai/blob/main/README.md). The macOS arm64 extension is 2.2 MB compressed before any model. It is a loadable extension with the same loading problem as section 3, and a far larger native surface than this task needs. Not relevant here beyond noting it exists.

### 4.5 Cost for this library

Assumed: 8,000 channels and 72,000 programmes. Programme ids are reassigned on every import, so vectors keyed by programme id would be recomputed every time; keyed by a hash of the text they survive, and a 7-day guide repeats many titles. How many distinct titles and descriptions the real guide holds is **[not verified]** (the library was not opened).

**Time to embed, with `NLEmbedding`, one thread, no reuse** **[computed from the timings in 4.1]**:

| What | Rows | Per row | Total |
| --- | ---: | ---: | ---: |
| Channel names | 8,000 | 1.9 ms | about 15 s |
| Programme titles | 72,000 | 1.9 ms | about 2 min 20 s |
| Programme title + description | 72,000 | 8.7 ms | about 10 min 30 s |

That is added to every guide import unless vectors are cached by text. Spread over several cores (one `NLEmbedding` instance each) it shortens, at the cost of the Mac's fans. Either way it is a new, sustained CPU load that the app does not have today.

**Storage** (vector bytes only, before SQLite's row and page overhead):

| Representation | Bytes per row | 72,000 programmes | 8,000 channels |
| --- | ---: | ---: | ---: |
| 512 × float32 | 2,048 | 147 MB | 16 MB |
| 384 × float32 | 1,536 | 111 MB | 12 MB |
| 512 × float16 | 1,024 | 74 MB | 8 MB |
| 512 × int8 | 512 | 37 MB | 4 MB |
| 384 × int8 | 384 | 28 MB | 3 MB |
| 512 × 4-bit (TurboQuant, +12 bytes) | 268 | 19 MB | 2 MB |
| 512 × 1 bit | 64 | 5 MB | 0.5 MB |

With sqlite-vector the quantized copy is built from the stored column and kept beside it (2.2), so quantizing adds to the float32 figure instead of replacing it, unless the vectors are stored as `INT8` in the first place **[inferred]**.

**Query time per keystroke** **[measured here]**: embedding a one-word query, 1.0 ms. Scoring it against 72,000 × 512 float32 vectors held in memory with one Accelerate call (`cblas_sgemv`), 0.66 ms best of 10; 6.2 ms including a deliberately naive full sort of all 72,000 scores, which a top-50 selection would cut to near the scan time. So about 2 ms per keystroke, on a par with the current 2 ms channel query, with no extension.

**Memory**: the scan needs the vectors resident. 147 MB as float32, 37 MB as int8, held for as long as search is in use; or memory-mapped from a file and left to the page cache. Today's search holds nothing. Against "minimum system resources" this is the largest standing cost of the whole idea. The `NLEmbedding` model's own footprint was not isolated **[not verified]**.

## 5. Do embeddings give a better "best match" here?

### 5.1 What is known

- Sentence-embedding models are trained on sentences and paragraphs. all-MiniLM-L6-v2's card calls it "a sentence and short paragraph encoder". A call sign is neither. **[the quote is the card's; the conclusion is this note's reasoning]**
- Dense retrieval is known to be weak on rare names and exact identifiers. Sciavolino et al., "Simple Entity-Centric Questions Challenge Dense Retrievers": "dense retrievers can only generalize to common entities unless the question pattern is explicitly observed during training", and they find dense models well behind sparse (lexical) ones on entity-rich questions (https://arxiv.org/abs/2109.08535).
- Lexical ranking holds up outside a model's training domain. The BEIR benchmark across 18 datasets: "Our results show BM25 is a robust baseline" (https://arxiv.org/abs/2104.08663).
- The usual production answer is hybrid: lexical and vector lists merged, commonly by reciprocal rank fusion (Cormack, Clarke and Büttcher, SIGIR 2009) **[general knowledge; the paper was not read for this note]**.

### 5.2 Channels: toy test with `NLEmbedding` **[measured here]**

Twenty made-up channel names in the style of the real ones; cosine similarity; top results in order.

| Query | Top results | Verdict |
| --- | --- | --- |
| `NBC` | USA  NBC 4 NY, **NBA TV**, USA: KNSD (NBC), **HGTV**, CNBC | An unrelated channel in second place; "US: NBC Sports Boston" not in the top five |
| `nbs` (typo) | USA  NBC 4 NY, NBA TV, ES: La 1, USA: KNSD (NBC) | Right first hit, noise after |
| `espm` (typo) | ESPN2 HD, ESPN, HGTV, DE: Das Erste | Works |
| `ESPN2` | ESPN2 HD, MSNBC, USA  NBC 4 NY, CNBC | Plain "ESPN" not in the top four |
| `KNSD` | **HGTV**, USA: KNSD (NBC), UK: BBC One | The exact call sign loses to an unrelated one |
| `french tv` | NBA TV, HGTV, USA: KNSD (NBC), USA  NBC 4 NY, FR: TF1 | Fails |

The model appears to break unknown tokens into pieces and match on letter overlap, which gives some typo tolerance and a lot of false neighbours. The lexical search gets `NBC`, `ESPN2` and `KNSD` exactly right and already orders them sensibly. **For channels, embeddings are worse than what exists**, and would be worse still as the only signal among 8,000 names, where many more near-identical short strings compete. **[the table is measured; the generalisation to 8,000 real names is reasoning]**

What channels do lack is typo tolerance ("nbs", "espm" find nothing today, since every term must match) and aliases. Both have cheaper fixes (section 6).

### 5.3 Programmes: toy test **[measured here]**

Twenty made-up programme titles.

| Query | `NLEmbedding` top results | Verdict |
| --- | --- | --- |
| `basketball` | NBA Basketball: Lakers at Celtics, NFL Football, SportsCenter, College Hoops Tonight; "WNBA: Liberty at Aces" absent | First hit contains the word; the conceptual ones are weak |
| `cooking shows` | **House Hunters**, Barefoot Contessa, College Hoops Tonight, Good Eats | Poor; Chopped, MasterChef, Bake Off missed |
| `soccer` | SportsCenter, PGA Tour Golf, College Hoops Tonight, NFL Football, Premier League (5th) | Poor |
| `nature documentary` | **Evening News**, Barefoot Contessa, SportsCenter; "Planet Earth" absent | Fails |
| `car racing` | Diners, Drive-Ins and Dives; PGA Tour Golf; ...; Formula 1 (5th) | Fails |
| `quiz` | Evening News, College Hoops Tonight, ...; Jeopardy! (5th) | Fails |

Averaged `NLContextualEmbedding` vectors were worse: "Chopped" came first for `nature documentary`, `car racing` and `quiz`, and "Barefoot Contessa" first for `basketball`.

Twenty titles is a toy, and titles alone are the hardest case: knowing that "Chopped" is a cooking show is world knowledge about a proper noun, which a small model has only if it saw the name in training. Real guide descriptions ("Four chefs compete...") give a model something to work with, and a model trained on a billion sentence pairs should do much better than Apple's on this. Both of those are expectations, **[not verified]**. What the test does establish: **Apple's built-in embeddings are not good enough to ship on titles**, so the zero-bundle-cost path to search by meaning is probably closed.

### 5.4 Where embeddings would help, honestly

- **Conceptual queries over programme descriptions**: "cooking shows", "true crime", "nature documentary". This is the one clear gain, and it needs a real sentence model. **[reasoning]**
- **Cross-language** ("football" finding "Fútbol"): only with a multilingual model, five times the size (4.3). **[reasoning]**
- **Not** for acronyms, call signs, channel numbers, typos in short tokens, or "best match" among names that all contain the typed word. Those are lexical problems. **[5.1 and 5.2]**
- Embeddings always return something. A vector search has no natural "no match", so a threshold has to be tuned or junk appears under every query; lexical search fails cleanly. **[reasoning]**

## 6. Alternatives with less machinery

**FTS5 trigram tokenizer.** "The trigram tokenizer extends FTS5 to support substring matching in general, instead of the usual token matching", and "FTS5 tables that use the trigram tokenizer also support indexed GLOB and LIKE pattern matching" unless `remove_diacritics` is set (https://www.sqlite.org/fts5.html, "The Trigram Tokenizer"). Added in SQLite 3.34.0, 2020-12-01 (https://www.sqlite.org/releaselog/3_34_0.html). Available in the system SQLite: a trigram table was created and queried through `/usr/lib/libsqlite3.dylib` **[checked here]**. Limits: "Substrings consisting of fewer than 3 unicode characters do not match any rows when used with a full-text query", so one- and two-letter queries still need today's path; and it is substring matching, not typo tolerance, unless the query is itself broken into trigrams joined with OR and ranked by how many hit. In a quick trial `bm25()` over a trigram table ranked "CNBC" above "USA  NBC 4 NY" for `nbc` **[checked here]**, which is the very ordering the last fix removed. For 8,000 names the current `LIKE` scan already takes about 2 ms, so trigram's index buys little. **Low value here.**

**`bm25()` with column weights.** "The better the match, the numerically smaller the value returned", and "each column of the table may be assigned a different weight", for example `ORDER BY bm25(email, 10.0, 5.0)` (same page, "The bm25() function"). Built in; nothing to add. For programmes this would replace the present two-step order (title or sub-title first, then the rest; `Store+Search.swift:76`, `:84`) with a graded one, e.g. `bm25(programme_fts, 10, 4, 1)`, so that a title made of exactly the typed words outranks a long title that merely contains them. It does not help channels: bm25 on one short column mostly rewards short names, which `length(c.name)` already does. **Small, safe, worth doing for programmes.**

**spellfix1.** "The spellfix1 virtual table is not included in the SQLite amalgamation and is not a part of any standard SQLite build. It is a loadable extension" (https://www.sqlite.org/spellfix1.html). Not in the system SQLite: "no such module: spellfix1", and `editdist3` is absent **[checked here]**. Loading it hits the same wall as section 3. **Not available.**

**Edit distance in Swift.** The same effect without any extension. On a query that the lexical search answers with few or no channels, compute a bounded Damerau-Levenshtein distance between each typed term and each distinct word of the channel names (a few thousand distinct words across 8,000 names), accept distance 1 for terms of 4 or 5 letters and 2 for longer, and list those channels after the exact matches. That is on the order of ten thousand short comparisons per keystroke, comfortably under a millisecond **[inferred; not measured]**. It fixes "espm" and "nbs" deterministically, explains itself, and cannot return nonsense. **Best value for the typo problem.**

**Alias table.** A small table mapping what people type to what the names say: network to affiliate call signs, spaced and unspaced forms ("espn 2", "espn2"), common short forms. Looked up before the search and added as alternative terms. Part of this already comes free from the names themselves when they carry both, as "USA: KNSD (NBC)" does. The cost is curation: a call-sign list is data someone has to supply and keep, and it is region-specific. A first version could be derived from the library itself (names holding both a call sign and a network in brackets) **[inferred]**. **Good value where the names lack the network; modest effort.**

**Hybrid search with reciprocal rank fusion.** Run lexical and vector searches, merge by summing 1 ÷ (k + rank) over the lists. This is how embeddings should be added if they are added: lexical results keep their place for exact queries, vector results fill in when the words do not match. It is a ranking rule of a few lines, on top of everything section 4 costs. **Only relevant after the experiment.**

## 7. Recommendation

### 7.1 Options ranked

| # | Option | Helps the owner's real queries | Bundle | CPU and memory | Import time | Licence risk | Stability risk | Effort |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Edit-distance fallback for channel names, in Swift | Typos in channel names | none | negligible | none | none | very low | about a day, with tests |
| 2 | `bm25()` weights for programmes | Better order among programme hits | none | none | none | none | very low | hours |
| 3 | Alias table for channels | Network ↔ call sign, spacing variants | a few KB | negligible | none | none | low; data upkeep | a day or two |
| 4 | Experiment: programme search by meaning, test-only (7.2) | Tells whether 5 is worth it | none | none shipped | none | none | none | half a day |
| 5 | Programme search by meaning: MiniLM via Core ML, vectors in a BLOB column keyed by text hash, Accelerate scan, fused with lexical by RRF | Conceptual queries, if 4 says so | +23 to 91 MB | +28 to 147 MB resident while searching; about 2 ms per keystroke | minutes per import, less with reuse | Apache 2.0 model; notice only | medium: model loading, cache invalidation, a threshold to tune | one to two weeks |
| 6 | The same with `NLEmbedding` | Poor in the toy test | none | as 5 at 512 dimensions | 2 to 10 min | none | medium; model may change with the OS | several days |
| 7 | sqlite-vector for the scan | Nothing over 5 at this size | +0.2 MB, 10,500 lines of C vendored | saves a few MB with quantization | adds a re-quantize per import | Apache 2.0; notice and licence text | higher: young C code with process-wide state, on every connection | days, plus upkeep of a vendored copy |
| 8 | Embeddings for channel names | Worse than today (5.2) | — | — | — | — | — | not recommended |

Do 1, 2 and 3 in that order; they are independent of each other and of the embedding question. Run 4 whenever the owner wants an answer about search by meaning. Consider 5 only on a clear win in 4. Skip 6, 7 and 8.

sqlite-vector becomes worth another look only if the vector count grows past what a plain scan handles comfortably, somewhere in the high hundreds of thousands of rows, or if the vectors must stay out of memory. This library is an order of magnitude short of that. **[inferred from 2.3 and 4.5]**

### 7.2 The smallest experiment

Purpose: find out whether vectors beat the current lexical ranking on this library's kind of data, before any of it is built.

- **Where**: a test or a small command-line target in the package, never linked into the app. No schema change, no extension.
- **Data**: a fixture of a few thousand programme titles with descriptions, written by hand or taken from a public XMLTV sample; not the owner's library. If the owner wants it run on the real guide, they run it themselves and only the rankings are looked at.
- **Queries**: twenty to thirty the owner would really type, half exact (a show name, a team), half conceptual ("basketball", "cooking shows", "nature documentary", "kids cartoons").
- **Arms**: (a) today's `Store.search`; (b) `NLEmbedding` on title + description, brute-force cosine with Accelerate; (c) all-MiniLM-L6-v2 embeddings computed offline once by a Python script and loaded from a file, so that no Core ML or tokenizer work is needed to learn the answer; (d) a + c fused by reciprocal rank.
- **Measure**: for each query, the owner marks which of the top ten in each arm they would have wanted. Compare counts. Also record embed time and vector size for the fixture.
- **Decide**: go on to option 5 only if (d) finds wanted programmes that (a) misses on a clear majority of the conceptual queries, and loses nothing on the exact ones. If (b) turns out as good as (c), prefer it, since it costs no bundle size. If neither helps, close the question.

## 8. Not verified

- That a proper sentence model (all-MiniLM-L6-v2) ranks conceptual programme queries well on real guide data. Expected, not shown. Section 7.2 exists to settle it.
- All quality results in section 5 come from twenty made-up channel names and twenty made-up titles, with no descriptions. They show direction, not size. Nothing was run on the owner's library, which was not opened.
- How many distinct titles and descriptions the real 72,000 programmes contain, and so how much import time reuse by text hash would save.
- Core ML figures for MiniLM: converted model size, per-string speed, memory. No conversion was done. Whether a trustworthy ready-made Core ML build exists.
- The memory footprint of the `NLEmbedding` model alone, and its speed on several cores.
- Whether `NLEmbedding` sentence embeddings for the languages that returned `nil` (French, German, Portuguese and others) can be downloaded, and what the OS does to fetch them. Whether Apple may change the model under revision 1 between OS releases.
- That sqlite-vector, compiled in with `SQLITE_CORE`, actually runs correctly against Apple's SQLite 3.54.0 and under a GRDB `DatabasePool` (read-only reader connections, concurrent readers, its process-wide state). It was compiled and linked, not executed.
- That calling the prebuilt framework's entry point on a system connection crashes. This follows from the SQLite source and the binary's symbol table; it was not run.
- sqlite-vector's benchmark numbers; they are the vendor's. The 1.8 ms figure for this library is a linear extrapolation.
- The licence of the `fp16` headers vendored in sqlite-vector's tree (no licence file beside them), and that no third-party code other than `fp16` is compiled into the extension.
- Which exact commit on 2026-09-10 switched the licence; only the before and after states were read. This note is not legal advice.
- The speed of the proposed edit-distance fallback, and how many false matches distance-1 and distance-2 rules produce among 8,000 real names.
- The reciprocal rank fusion paper and the claim that hybrid search is the usual production answer were not read in a primary source for this note.
