# Restore Session History — Rencana Implementasi

Fitur baru: tombol in-app **"Restore Session History…"** yang mengembalikan tiap
profil ke sesi **per-akun**-nya yang persis, diambil dari folder
`claude-session-backup-*` (backup yang dibuat otomatis saat sharing di-*enable*).
Ini menutup celah "true rollback" — `disableSharedHistory()` yang ada sekarang
cuma memberi tiap profil salinan blob gabungan, bukan pemisahan sejati.

---

## Batas yang harus jujur (baca dulu — ini menentukan scope)

Rollback per-akun terbelah dua, dan separuhnya adalah **batas desain**, bukan
sesuatu yang bisa ditutup kode:

| Sesi | Bisa dikembalikan per-akun? | Cara |
|------|------------------------------|------|
| Dibuat **sebelum** enable | ✅ Persis, byte-for-byte | Ada di `claude-session-backup-*`, tinggal salin balik |
| Dibuat **selama** sharing aktif | ❌ Tidak bisa | Semua akun di-*funnel* ke satu master dir lewat symlink; account-id di path sudah diganti symlink → asal-usul hilang |

Karena itu fitur ini:
- **Memulihkan** persis sesi pre-enable dari backup.
- **Mengarsipkan** (bukan menghapus) tumpukan gabungan `_shared-sessions` ke
  `~/claude-shared-archive-<timestamp>` — sesi post-enable selamat sebagai satu
  pile, tapi tidak terpisah per-akun. Itu batasnya, dan itu didokumentasikan,
  bukan TODO.

---

## Prasyarat

1. **Working tree sekarang semua `.swift` ke-`deleted` (uncommitted).** Pulihkan
   dulu sebelum implementasi:
   ```bash
   git restore Sources Tests
   ```
2. Restore butuh **Claude dalam keadaan quit** — sama seperti enable/disable. UI
   yang menegakkan lewat `claude.quit()`; core tidak (tidak bisa lihat proses).

---

## Perubahan inti — `Sources/ClaudeProfilesCore/ProfileManager.swift`

### 1. Refactor (reuse, bukan duplikasi)

Blok backup di dalam `enableSharedHistory()` (baris ~198–217) diekstrak jadi
helper yang dipakai ulang oleh enable **dan** restore:

```swift
/// Salin tiap tree sesi yang masih REAL (belum jadi symlink) ke
/// ~/claude-session-<tag>-<timestamp>/<profil>/<tree>. Nil kalau tak ada yang real.
private func backupRealTrees(tag: String, now: Date) throws -> URL? {
    let names = profiles()
    var real: [(String, String)] = []
    for p in names {
        for tree in Self.sessionTrees
        where isRealDirectory(profilesDir.appendingPathComponent(p).appendingPathComponent(tree)) {
            real.append((p, tree))
        }
    }
    guard !real.isEmpty else { return nil }
    let dir = home.appendingPathComponent("claude-session-\(tag)-\(timestamp(now))")
    for (p, tree) in real {
        let src = profilesDir.appendingPathComponent(p).appendingPathComponent(tree)
        let dst = dir.appendingPathComponent(p).appendingPathComponent(tree)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dst)
    }
    return dir
}

private func timestamp(_ now: Date) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    return fmt.string(from: now)
}
```

`enableSharedHistory()` memanggil `backupRealTrees(tag: "backup", now: now)` →
nama `claude-session-backup-<ts>` tetap sama, jadi perilaku & test lama tak berubah.

### 2. `restoreFromBackup(_:now:)`

```swift
public struct RestoreResult {
    public let prerestoreBackup: URL?  // state saat ini, disimpan supaya restore reversible
    public let sharedArchive: URL?     // _shared-sessions yang diarsipkan (pile post-enable)
}

/// Kembalikan tiap profil ke sesi per-akunnya dari `backupDir`. Butuh Claude quit.
@discardableResult
public func restoreFromBackup(_ backupDir: URL, now: Date = Date()) throws -> RestoreResult {
    // 1. Validasi: folder harus punya minimal satu <profil>/<sessionTree> real.
    guard isRealDirectory(backupDir),
          (try realSubdirectories(of: backupDir)).contains(where: { prof in
              Self.sessionTrees.contains { isRealDirectory(prof.appendingPathComponent($0)) }
          })
    else { throw ProfileError.invalidBackup(backupDir.lastPathComponent) }

    // 2. Amankan state sekarang dulu (restore-nya sendiri jadi reversible).
    let prerestore = try backupRealTrees(tag: "prerestore", now: now)

    // 3. Reset tiap profil yang ADA ke isi backup (atau folder kosong kalau
    //    profil itu tak ada di backup, mis. dibuat setelah enable).
    for name in profiles() {
        for tree in Self.sessionTrees {
            let target = profilesDir.appendingPathComponent(name).appendingPathComponent(tree)
            if itemExists(target) { try fm.removeItem(at: target) } // symlink atau dir
            let src = backupDir.appendingPathComponent(name).appendingPathComponent(tree)
            if isRealDirectory(src) {
                try fm.copyItem(at: src, to: target)               // pre-enable, persis per-akun
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true) // kosong
            }
        }
    }

    // 4. Arsipkan pile gabungan (jangan hapus) — juga membuat sharedHistoryEnabled=false.
    var archive: URL?
    if isRealDirectory(sharedDir) {
        let dst = home.appendingPathComponent("claude-shared-archive-\(timestamp(now))")
        try fm.moveItem(at: sharedDir, to: dst)
        archive = dst
    }
    return RestoreResult(prerestoreBackup: prerestore, sharedArchive: archive)
}
```

**Kenapa dua backup (prerestore + archive) selalu menyelamatkan state lama:**
- Sharing **ON** → tree profil semua symlink → step 2 nihil, tapi step 4
  mengarsipkan `_shared-sessions` (data asli). ✅
- Sharing **OFF** (mis. setelah disable lossy, ada sesi baru) → tree real →
  step 2 menyimpannya ke `claude-session-prerestore-*`, step 4 nihil. ✅

### 3. Error baru

```swift
case invalidBackup(String)  // + pesan di localizedDescription: "… bukan folder backup sesi yang valid"
```

---

## UI — `AppState.swift` + View

### `AppState.restoreSharedHistory()`

Pola persis meniru `enableSharedHistory()` / `disableSharedHistory()`
(NSOpenPanel → NSAlert konfirmasi → `run { quit → manager call → relaunch → Notifier }`):

```swift
func restoreSharedHistory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = manager.home
    panel.message = "Pilih folder claude-session-backup-… yang dibuat saat sharing dinyalakan."
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let dir = panel.url else { return }

    let alert = NSAlert()
    alert.messageText = "Kembalikan riwayat per-akun dari backup ini?"
    alert.informativeText = "Tiap profil di-reset ke sesinya sendiri dari \(dir.lastPathComponent). "
        + "Daftar sesi saat ini diarsipkan ke home folder dulu (tidak ada yang dihapus). "
        + "Sesi yang dibuat selama sharing aktif tak bisa dilacak per-akun dan ikut diarsip, "
        + "bukan dipulihkan. Claude akan restart."
    alert.addButton(withTitle: "Restore")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { refresh(); return }
    run {
        guard await self.claude.quit() else { return self.abortQuitFailed() }
        do {
            let r = try self.manager.restoreFromBackup(dir)
            self.claude.relaunch()
            Notifier.post("Riwayat dipulihkan",
                          r.sharedArchive.map { "Pile gabungan diarsip: \($0.lastPathComponent)" }
                            ?? "Tiap profil dikembalikan.")
        } catch {
            self.claude.relaunch()
            Notifier.post("Restore gagal", error.localizedDescription)
        }
        self.refresh()
    }
}
```

### Entry point (satu tempat cukup)

Tambah `ActionRow` di section **"Session History"** pada `WindowView.swift`
(GroupBoxList di bawah toggle, baris ~86), **selalu tampil** (beda dari Share row
yang hanya muncul saat `!sharedHistoryEnabled` — restore juga berguna setelah
disable lossy):

```swift
ActionRow(icon: "arrow.uturn.backward", title: "Restore Session History…",
          disabled: !state.claudeAppFound || state.isSwitching) {
    state.restoreSharedHistory()
}
```

(Opsional: cerminkan juga di `moreTab` di `ClaudeProfilesApp.swift` ~664. Tidak wajib.)

---

## Tests — `Tests/ClaudeProfilesCoreTests/ProfileManagerTests.swift`

Pakai scaffolding & helper yang ada (`seedTwoProfiles`, `write`, `profile`,
`isRealDir`, `isSymlink`). Tambah:

1. **`testRestoreSeparatesPerAccount`** — inti fitur:
   `seedTwoProfiles` → `enableSharedHistory()` (simpan `backup`) → tulis satu sesi
   post-enable lewat path symlink profil a (`.../acct1/org1/post_enable.json`) →
   `restoreFromBackup(backup!)`. Assert:
   - `pm.sharedHistoryEnabled == false`, `sharedDir` hilang, ada `claude-shared-archive-*` yang memuat `post_enable.json`.
   - tree a real & isinya **persis** `local_1/local_2` (tanpa `local_3`, tanpa `post_enable`); tree b real & isinya `local_3` + `agent.json`.
2. **`testRestoreEmptyTreeForProfileNotInBackup`** — buat profil "c" **setelah**
   enable (jadi symlink, tak ada di backup) → restore → tree c = folder real **kosong**.
3. **`testRestoreRejectsInvalidBackup`** — `restoreFromBackup(home/"random")`
   melempar `invalidBackup`, dan tak ada tree yang berubah.
4. **`testRestoreBacksUpCurrentRealTrees`** — enable → disable (tree jadi real) →
   tulis sesi baru di tree a → restore(backup). Assert `claude-session-prerestore-*`
   memuat sesi baru itu (restore reversible), dan tree a kini cocok dengan backup asli.

---

## Corner & ceiling

- **Tidak transaksional** antar profil/tree. Kalau gagal di tengah, `prerestore`
  + `archive` adalah jalur pemulihan. Tandai:
  `// ponytail: not transactional across profiles; prerestore backup is the recovery path.`
- **Validasi** menolak user yang salah pilih folder acak (step 1).
- Profil ada di backup tapi **sudah dihapus** sekarang → dilewati (kita hanya
  iterasi `profiles()` yang ada). Sesi tak menghidupkan kembali profil yang di-logout.
- Profil **baru** (post-enable, tak ada di backup) → dapat tree real kosong (state per-akun yang jujur: memang belum punya riwayat).

---

## Di luar scope (YAGNI — jangan dibangun kecuali diminta)

- Membaca isi file sesi JSON untuk **menebak** akun pemilik sesi post-enable.
  Ini satu-satunya cara "memisahkan" pile post-enable, dan hasilnya fragile —
  batas desain, bukan fitur.
- Auto-deteksi/pilih backup terbaru otomatis (MVP pakai picker manual).
- Retensi/cleanup backup, UI preview/diff sebelum restore, progress bar.

---

## Peluang sekaligus (opsional, 1 baris)

Ekstraksi `backupRealTrees` juga menutup celah lama "`disableSharedHistory()`
tidak bikin backup": tambahkan `try backupRealTrees(tag: "predisable", now: now)`
di awal `disableSharedHistory()`. Di luar scope utama, tapi murah.

---

## Checklist file yang disentuh

- [ ] `git restore Sources Tests` (pulihkan working tree dulu)
- [ ] `ProfileManager.swift` — `backupRealTrees`, `timestamp`, `restoreFromBackup`, `RestoreResult`, refactor `enableSharedHistory`, `ProfileError.invalidBackup`
- [ ] `AppState.swift` — `restoreSharedHistory()`
- [ ] `WindowView.swift` — `ActionRow` "Restore Session History…" di section Session History
- [ ] `ProfileManagerTests.swift` — 4 test di atas
- [ ] `README.md` — 2–3 baris dokumentasi Restore + catatan batas post-enable

**Estimasi:** ~70 LOC core, ~30 UI, ~60 test. Tanpa dependency baru.
