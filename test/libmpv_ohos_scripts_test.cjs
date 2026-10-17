// Guards for the OHOS libmpv fetch script and the native player plugin.
//
// libmpv is a 24MB binary that must not be committed, so the only thing keeping
// the OHOS build reproducible is the pinned artifact in
// scripts/fetch_libmpv_ohos.ps1. These assertions pin the release, both digests
// and the install path, and check that the ArkTS plugin is actually registered
// (a plugin that never reaches the engine leaves the Dart channel unanswered,
// which is indistinguishable at runtime from "playback is broken").
//
// Run with: node --test test/libmpv_ohos_scripts_test.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const appDir = path.resolve(__dirname, '..');

function read(relative) {
  return fs.readFileSync(path.join(appDir, relative), 'utf8');
}

test('the libmpv fetch script pins one verified artifact', () => {
  const name = 'fetch_libmpv_ohos.ps1';
  const source = read(path.join('scripts', name));

  // The upstream release media_kit itself builds against.
  assert.ok(
    source.includes('p1nbored/libmpv-ohos-build'),
    `${name} must fetch from the pinned repository`,
  );
  assert.ok(
    source.includes('20261013-hdr'),
    `${name} must pin the release tag`,
  );
  assert.ok(
    source.includes('libmpv_aarch64.zip'),
    `${name} must fetch the libmpv asset`,
  );

  // Both digests and the size are the guard against a silently replaced
  // upstream asset, which would otherwise be baked into every HAP.
  assert.ok(
    source.includes(
      '140e2c5a6d38572a1f8418cc2463c330077837a38609504c4d532825060e8617',
    ),
    `${name} must verify the archive digest`,
  );
  assert.ok(
    source.includes(
      '6add9a06c5c9f4993895a9aa7ef6f541c499d3d8461d949ce0ace2377acbf940',
    ),
    `${name} must verify the extracted library digest`,
  );
  assert.ok(
    source.includes('libmpv.so'),
    `${name} must install libmpv.so`,
  );
  assert.ok(
    source.includes('ohos\\entry\\libs') && source.includes('arm64-v8a'),
    `${name} must install into ohos/entry/libs/arm64-v8a`,
  );
  // media_kit opens the bare name on OHOS, so the library has to reach the HAP
  // through the module's libs directory, not a build-output path.
  assert.ok(
    source.includes("DynamicLibrary") || source.includes('bare name'),
    `${name} must document why the library lives in libs/`,
  );
});

test('the libmpv script tolerates the Windows schannel failure', () => {
  const source = read(path.join('scripts', 'fetch_libmpv_ohos.ps1'));
  // curl to github.com fails on this machine with
  // CRYPT_E_NO_REVOCATION_CHECK unless revocation checking is disabled.
  assert.ok(
    source.includes('--ssl-no-revoke'),
    'curl fallback must disable revocation checking',
  );
  // gh is tried first because it does not go through schannel at all.
  assert.ok(
    source.includes('gh release download'),
    'the script must prefer gh release download over raw curl',
  );
});

test('the fetch script also installs libc++_shared.so beside libmpv', () => {
  const source = read(path.join('scripts', 'fetch_libmpv_ohos.ps1'));
  // libmpv.so has DT_NEEDED libc++_shared.so and HarmonyOS devices do not ship
  // one system-wide; without it dlopen fails at MediaKit.ensureInitialized and
  // the whole OHOS playback backend is dead on arrival.
  assert.ok(
    source.includes('libc++_shared.so'),
    'the script must install libc++_shared.so next to libmpv.so',
  );
  assert.ok(
    source.includes('aarch64-linux-ohos'),
    'the script must target the arm64 OHOS NDK runtime',
  );
  // The libmpv fast-path used to `exit 0` before reaching the libc++ section,
  // silently skipping the dependency on every machine where libmpv was already
  // fetched. Guard the structure instead of the exact wording.
  assert.ok(
    source.includes('$NeedLibmpv'),
    'the libmpv fast path must fall through to the libc++ section',
  );
});

test('libmpv stays out of Git like the other OHOS build outputs', () => {
  const ignore = read(path.join('ohos', '.gitignore'));
  assert.ok(
    ignore.includes('**/libs/**/libmpv.so'),
    'the OHOS project must ignore the fetched libmpv',
  );
  assert.ok(
    ignore.includes('**/libs/**/libc++_shared.so'),
    'the OHOS project must ignore the copied libc++ runtime',
  );
  assert.ok(
    ignore.includes('**/libs/**/libfqapi_core.so'),
    'the Rust core ignore rule must stay intact',
  );
});

test('the native player plugin is registered with the engine', () => {
  const plugin = path.join(
    'ohos',
    'entry',
    'src',
    'main',
    'ets',
    'plugins',
    'NativePlayerPlugin.ets',
  );
  assert.ok(fs.existsSync(path.join(appDir, plugin)), `${plugin} must exist`);
  const source = read(plugin);

  // The channel name is the whole contract with lib/services/native_player.dart.
  assert.ok(
    source.includes("'fqapp/native_player'"),
    'the plugin must serve the channel the Dart side opens',
  );
  for (const method of ['setKeepScreenOn', 'startListenForeground', 'stopListenForeground']) {
    assert.ok(
      source.includes(method),
      `the plugin must handle ${method}`,
    );
  }

  // GeneratedPluginRegistrant.ets is generated by the Flutter tool and must not
  // be edited, so registration has to happen in the ability.
  const ability = read(
    path.join(
      'ohos',
      'entry',
      'src',
      'main',
      'ets',
      'entryability',
      'EntryAbility.ets',
    ),
  );
  assert.ok(
    ability.includes('new NativePlayerPlugin()'),
    'EntryAbility must attach NativePlayerPlugin; the generated registrant cannot be edited',
  );
  assert.ok(
    ability.includes('getPlugins()?.add('),
    'the plugin must be added through the engine plugin registry',
  );

  const registrant = read(
    path.join(
      'ohos',
      'entry',
      'src',
      'main',
      'ets',
      'plugins',
      'GeneratedPluginRegistrant.ets',
    ),
  );
  assert.ok(
    !registrant.includes('NativePlayerPlugin'),
    'the generated registrant must not be hand-edited',
  );
});
