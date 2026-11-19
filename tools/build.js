/**
 * Lazer 插件打包工具
 *
 * 校验 manifest.json，把插件实体文件打成一个 ZIP（根目录必须是 manifest.json），
 * 输出 SHA-256、文件清单，以及可直接粘进插件市场索引的 JSON 片段。
 *
 * 用法：node tools/build.js
 * 产物：dist/<manifest.id>.zip
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const ROOT_DIR = path.resolve(__dirname, '..');
const DIST_DIR = path.join(ROOT_DIR, 'dist');
const MANIFEST_PATH = path.join(ROOT_DIR, 'manifest.json');

// ZIP 里必须打进去的目录；其余（test/tools/docs/.github）都是仓库侧文件。
const PACK_DIRS = ['bili'];

function log(msg) {
  console.log(`[Build] ${msg}`);
}

function fail(msg) {
  console.error(`[Build Error] ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(MANIFEST_PATH)) {
  fail('manifest.json 不存在');
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
} catch (e) {
  fail('manifest.json 不是合法 JSON：' + e.message);
}

for (const key of ['id', 'name', 'version', 'entry', 'provider', 'apiVersion']) {
  if (manifest[key] === undefined || manifest[key] === null || manifest[key] === '') {
    fail(`manifest.json 缺少必要字段: ${key}`);
  }
}

const idRegex = /^[a-z][a-z0-9_.-]{2,79}$/;
if (!idRegex.test(manifest.id)) {
  fail(`manifest.id '${manifest.id}' 不符合 ${idRegex} 规范`);
}

if (manifest.entry !== 'main.lua') {
  fail(`入口必须是 ZIP 根目录的 main.lua，当前为 ${manifest.entry}`);
}

const entryPath = path.join(ROOT_DIR, manifest.entry);
if (!fs.existsSync(entryPath)) {
  fail(`入口文件不存在: ${manifest.entry}`);
}

// Lazer 侧的限制（见 README「包体限制」），超了会在导入阶段被拒。
const ZIP_LIMIT = 16 * 1024 * 1024;
const UNPACKED_LIMIT = 8 * 1024 * 1024;

// ---- 收集待打包文件（保持相对路径，正斜杠）----
const filesToPack = [];

function addFile(fullPath, relPath) {
  const data = fs.readFileSync(fullPath);
  if (data.length > 2 * 1024 * 1024) {
    fail(`单文件超过 2 MB 上限: ${relPath} (${data.length} B)`);
  }
  filesToPack.push({ fullPath, relPath, data });
}

addFile(MANIFEST_PATH, 'manifest.json');
addFile(entryPath, manifest.entry);

for (const dir of PACK_DIRS) {
  const abs = path.join(ROOT_DIR, dir);
  if (!fs.existsSync(abs)) {
    fail(`源码目录不存在: ${dir}/`);
  }
  const walk = (current, base) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      const rel = path.posix.join(base, entry.name);
      if (entry.isDirectory()) {
        walk(full, rel);
      } else if (entry.isFile()) {
        addFile(full, rel);
      }
    }
  };
  walk(abs, dir);
}

// 插件侧 README：Lazer 的插件详情页读 ZIP 内的 README.md。
// 仓库根目录的 README.md 是 GitHub 落地页，两者内容不同，所以源文件叫 README.plugin.md。
const readmePath = path.join(ROOT_DIR, 'README.plugin.md');
if (!fs.existsSync(readmePath)) {
  fail('README.plugin.md 不存在（ZIP 内会被重命名为 README.md）');
}
addFile(readmePath, 'README.md');

filesToPack.sort((a, b) => (a.relPath < b.relPath ? -1 : a.relPath > b.relPath ? 1 : 0));

log(`待打包 ${filesToPack.length} 个文件:`);
for (const f of filesToPack) console.log(`  - ${f.relPath} (${f.data.length} B)`);

const unpackedSize = filesToPack.reduce((acc, f) => acc + f.data.length, 0);
if (unpackedSize > UNPACKED_LIMIT) {
  fail(`解压后总大小 ${unpackedSize} B 超过 ${UNPACKED_LIMIT} B 上限`);
}

// ---- 极简 ZIP 写入（deflate，无需第三方依赖）----
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let crc = -1;
  for (let i = 0; i < buf.length; i++) crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ buf[i]) & 0xff];
  return (crc ^ -1) >>> 0;
}

function buildZip(files) {
  const chunks = [];
  const central = [];
  let offset = 0;

  for (const file of files) {
    const nameBuf = Buffer.from(file.relPath, 'utf8');
    const compressed = zlib.deflateRawSync(file.data, { level: 9 });
    const crc = crc32(file.data);

    const local = Buffer.alloc(30 + nameBuf.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);   // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 文件名标志
    local.writeUInt16LE(8, 8);    // deflate
    local.writeUInt16LE(0, 10);   // time
    local.writeUInt16LE(0, 12);   // date
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(file.data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    nameBuf.copy(local, 30);

    chunks.push(local, compressed);

    const header = Buffer.alloc(46 + nameBuf.length);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(20, 4);    // version made by
    header.writeUInt16LE(20, 6);    // version needed
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(8, 10);
    header.writeUInt16LE(0, 12);
    header.writeUInt16LE(0, 14);
    header.writeUInt32LE(crc, 16);
    header.writeUInt32LE(compressed.length, 20);
    header.writeUInt32LE(file.data.length, 24);
    header.writeUInt16LE(nameBuf.length, 28);
    header.writeUInt16LE(0, 30);
    header.writeUInt16LE(0, 32);
    header.writeUInt16LE(0, 34);
    header.writeUInt16LE(0, 36);
    header.writeUInt32LE(0, 38);
    header.writeUInt32LE(offset, 42);
    nameBuf.copy(header, 46);
    central.push(header);

    offset += local.length + compressed.length;
  }

  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(files.length, 8);
  eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...chunks, centralBuf, eocd]);
}

const zipBuffer = buildZip(filesToPack);

if (zipBuffer.length > ZIP_LIMIT) {
  fail(`ZIP 大小 ${zipBuffer.length} B 超过 ${ZIP_LIMIT} B 上限`);
}

fs.mkdirSync(DIST_DIR, { recursive: true });
const outPath = path.join(DIST_DIR, `${manifest.id}.zip`);
fs.writeFileSync(outPath, zipBuffer);

const sha256 = crypto.createHash('sha256').update(zipBuffer).digest('hex');

log(`打包完成: ${path.relative(ROOT_DIR, outPath)} (${zipBuffer.length} B, ${filesToPack.length} 文件)`);
log(`SHA-256: ${sha256}`);
console.log('\n---- 插件市场索引片段 ----');
console.log(JSON.stringify({
  id: manifest.id,
  name: manifest.name,
  version: manifest.version,
  summary: manifest.description,
  author: manifest.author,
  sha256,
  size: zipBuffer.length,
  platforms: ['windows', 'macos', 'linux', 'android', 'ios'],
  minAppVersion: '2.0.0',
}, null, 2));
console.log('--------------------------\n');
