# Memeless — Supabase Setup Guide

## 1. Buat Project Supabase

1. Buka https://supabase.com
2. Klik **"New Project"**
3. Isi:
   - **Name**: `memeless`
   - **Database Password**: simpan password ini (butuh buat akses database jika diperlukan)
   - **Region**: pilih yang terdekat (misal Singapore)
4. Klik **"Create new project"**
5. Tunggu ~2 menit sampai project siap

---

## 2. Jalankan SQL Setup

1. Di dashboard Supabase, klik menu kiri **SQL Editor**
2. Klik **"New query"**
3. Copy paste isi file `supabase-setup.sql` ke SQL Editor
4. Klik **"Run"** (atau tekan Ctrl+Enter)
5. Verifikasi tabel dibuat:
   - Klik **Table Editor** di menu kiri
   - Harus ada tabel: `submissions` dan `admins`

---

## 3. Aktifkan Email Provider

1. Di menu kiri, klik **Authentication → Providers**
2. Cari **Email** provider
3. Pastikan toggle **"Email"** ON
4. (Opsional) Nonaktifkan **"Confirm email"** jika ingin user langsung login tanpa verifikasi email:
   - Klik **Email** → matikan **"Confirm email"**
5. Klik **Save**

---

## 4. Buat Akun Admin

### Opsi A: Langsung via Supabase Dashboard

1. Klik **Authentication → Users** di menu kiri
2. Klik **"Add user"** → **"Create new user"**
3. Isi:
   - **Email**: email admin (misal `admin@memeless.com`)
   - **Password**: password yang kuat
   - **Auto-confirm user**: ON
4. Klik **"Create user"**
5. Catat **User UUID** yang muncul (misal `a1b2c3d4-...`)
6. Kembali ke **SQL Editor**, jalankan:

```sql
INSERT INTO public.admins (user_id) VALUES ('PASTE-UUID-DISINI');
```

### Opsi B: Via aplikasi (jika sudah deploy)

1. Buka `/adminkece.html`
2. Login dengan email/password admin
3. Jika gagal "Not authorized", berarti UUID belum di-insert ke tabel `admins`

---

## 5. Verifikasi Storage Bucket

1. Klik **Storage** di menu kiri
2. Bucket `memeless-submissions` harus sudah ada (dibuat oleh SQL)
3. Klik bucket tersebut → **Permissions**
4. Pastikan policies terlihat:
   - Authenticated users can upload to `pending/`
   - Admins can view/delete `pending/`

Jika belum ada, jalankan ulang `supabase-setup.sql`

---

## 6. Dapatkan API Credentials

1. Klik **Project Settings** (icon gear di menu kiri bawah)
2. Klik **API**
3. Copy **Project URL** (misal `https://abcdefghijklmn.supabase.co`)
4. Copy **anon/public key** (bukan service_role!)
5. Paste ke kedua file HTML:

### Di `index.html` (baris ~1087-1088):
```javascript
const SUPABASE_URL = "https://PASTE-PROJECT-URL-DISINI";
const SUPABASE_ANON_KEY = "PASTE-ANON-KEY-DISINI";
```

### Di `adminkece.html` (baris ~326-327):
```javascript
const SUPABASE_URL = "https://PASTE-PROJECT-URL-DISINI";
const SUPABASE_ANON_KEY = "PASTE-ANON-KEY-DISINI";
```

---

## 7. Deploy ke Vercel

### Via Git (Recommended)

1. Push project ke GitHub/GitLab/Bitbucket
2. Buka https://vercel.com → **"Add New Project"**
3. Import repository
4. Di **Environment Variables**, tambah:
   - `NEXT_PUBLIC_SUPABASE_URL` → Project URL
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` → anon key
5. Klik **Deploy**

### Via Vercel CLI

```bash
vercel login
vercel
```

Kemudian di Vercel Dashboard → Settings → Environment Variables, tambah kedua env vars.

---

## 8. Testing Flow

### Test User Submission

1. Buka `index.html` langsung (atau via Vercel URL)
2. Scroll ke bawah, klik **"Submit a Meme"**
3. Pilih file `.mp4` (maks 50MB)
4. Klik **"Submit Meme"**
5. Harus muncul: `"Meme submitted successfully! It will be reviewed by an admin."`
6. Cek di Supabase → **Table Editor → submissions** harus ada record baru dengan `status: pending`

### Test Admin Queue

1. Buka `https://domain-kamu.com/adminkece.html`
2. Login dengan email/password admin yang dibuat di step 4
3. Harus muncul queue dengan video yang barusan di-submit
4. Test **Delete**: klik Delete → konfirmasi → item hilang
5. Test **Confirm**: 
   - Klik Confirm
   - Browser akan download MP4 dan JPG
   - Item hilang dari queue
   - Cek Supabase Storage → `pending/` harus kosong
   - Cek Table Editor → submissions harus kosong

---

## 9. Manual Git Workflow (Setelah Confirm)

Setelah admin confirm dan download MP4 + JPG:

```bash
# Di komputer admin (yang punya repo memeless)
cd memeless
# Pindahkan file yang didownload ke folder memes/
mv ~/Downloads/Ha\ Got\ Em.mp4 memes/
mv ~/Downloads/Ha\ Got\ Em.jpg memes/

# Commit dan push
git add .
git commit -m "Add approved memes"
git push
```

Setelah push, otomatis update di https://memeless-eosin.vercel.app/

---

## 10. Important Notes

- **Jangan pernah share** `service_role` key ke frontend
- **Jangan hardcode** credentials di file yang di-commit ke public repo
- Untuk production, sebaiknya gunakan **Vercel Environment Variables** + build step, bukan hardcode di HTML
- RLS policies sudah aktif — user biasa tidak bisa melihat/hapus submission orang lain
- Admin harus ada di tabel `admins` — hanya user yang ada di tabel ini yang bisa akses `/adminkece.html`

---

## Troubleshooting

| Error | Solusi |
|-------|--------|
| `Failed to load memes` | Cek `githubOwner`, `githubRepo`, `branch` di `index.html` baris 633-637 |
| `Not authorized as admin` | User belum di-insert ke tabel `admins` |
| `Bucket not found` | Jalankan ulang `supabase-setup.sql` |
| Upload gagal | Cek storage policies, pastikan user sudah login |
| Video tidak muncul di admin | Cek RLS policies, pastikan admin role aktif |
| `Identifier 'supabase' has already been declared` | Sudah diperbaiki dengan `supabaseClient` |
