# Hermes Port — validate-skills & committer (Python)

Port Python dari script upstream, dipakai untuk kolam skill Hermes kita
(`~/.hermes/skills`, multi-kategori bersarang).

**Kenapa ada:** script upstream `validate-skills` ditulis Ruby dan hanya memindai
pola flat `skills/*/SKILL.md`. Server Hermes kita **tidak punya Ruby**, dan struktur
skill kita bersarang (`<kategori>/[<subkategori>/]<skill>/SKILL.md`). Jadi di-port
ke Python + pola glob disesuaikan.

Catatan: `scripts/committer` **sudah tidak ada** di upstream (diganti `sync-skills`).
Versi di sini dibuat dari filosofi aslinya, disesuaikan alur kerja kita.

## Isi

| File | Fungsi |
|---|---|
| `scripts/validate-skills-python` | Validasi semua SKILL.md (front matter, `name`, `description`, nama kembar, anti-pola `gh secret --body -`) |
| `scripts/committer` | Commit aman: stage eksplisit, pesan wajib, validasi dulu, tolak file rahasia |
| `hooks/pre-commit-python` | Hook git: jalankan validator sebelum commit |

## Pemakaian

```bash
# validasi seluruh kolam
python3 scripts/validate-skills-python --root ~/.hermes/skills

# hanya file yang berubah (cepat)
python3 scripts/validate-skills-python --only-changed --json

# commit aman (stage EKSPLISIT — tidak akan menyedot file sampah)
python3 scripts/committer --repo <repo> -m "pesan" file1 file2

# lihat rencana tanpa commit
python3 scripts/committer --repo <repo> -m "pesan" --dry-run file1

# pasang hook
git config core.hooksPath /opt/data/scripts/hooks
```

Exit code: `0` lolos, `1` ada error, `2` salah pemakaian.

## Yang diperiksa validator

1. Front matter ada, mulai baris 1, ditutup `---`, valid YAML mapping
2. `name` + `description` string non-kosong
3. **`name` duplikat lintas skill** — paling sering ketemu di kolam besar
4. `description` berupa block scalar (`|`) yang gagal parse
5. Anti-pola `gh secret set ... --body -` (dari upstream)

## Temuan nyata saat pertama dipakai

Validasi 491 skill Hermes langsung menemukan 2 bug yang tidak terdeteksi sebelumnya:

1. **YAML rusak** — satu skill menaruh `Source: repo/name` di dalam `description`
   tanpa tanda kutip → YAML gagal parse, skill itu tidak pernah terbaca router.
   *Fix:* kutip `description` yang mengandung tanda `:`.

2. **Nama skill kembar** — `seo-audit` ada di dua kategori berbeda (workflow umum
   vs varian claude-seo). Nama skill harus unik **global**, bukan cuma per kategori.
   *Fix:* rename folder + field `name`.

## Pitfall

- **Jangan `cp -a` folder skill ke dalam folder skill lain.** Backup bisa nyasar
  jadi `<skill>/<subfolder>/<skill>/` — validator lapor nama kembar dari file tak
  terduga dan `references/` ikut kebawa. Backup SELALU ke luar tree (`/opt/backups/`).
- **Folder `skills/skills/`** di dalam kolam = sisa migrasi, isinya salinan kolam.
  Berbahaya: salinannya bisa memuat skill yang sudah tidak ada di tree utama.
  Hitung dulu mana yang unik sebelum membuang.
- **`.archive/`** — banyak skill "hilang" ternyata sengaja diarsipkan. Cek dulu.

## Protokol bersih-bersih kolam (terbukti)

1. Backup ke luar tree: `cp -a <target> /opt/backups/skills_cleanup_$(date +%Y%m%d_%H%M%S)/`
2. Bangun daftar nama skill sebelum & sesudah (`os.walk` cari `SKILL.md`)
3. Kalau membuang duplikat: hitung dulu mana yang **cuma ada di salinan**
4. Yang unik → pulihkan ke `root/<kategori>/<skill>` (pertahankan kategori)
5. Verifikasi: `set(before) - set(after)` HARUS kosong
6. Baru jalankan validator — harus exit 0

## Lisensi

Mengikuti lisensi repo upstream (MIT). Lihat `LICENSE`.
