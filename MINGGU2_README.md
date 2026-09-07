# Minggu 2 — S3, Lifecycle, dan IAM

Semua kode di sini sudah lolos validasi sintaks. Belum pernah di-`apply`,
karena akun AWS-nya belum ada. Begitu akunnya siap, urutannya di bawah.

---

## Yang dibangun

| Resource | Fungsi | Biaya |
|---|---|---|
| S3 bucket | Menyimpan backup | ~$0.01/bulan (data kecil) |
| Versioning | Backup rusak tidak menimpa yang bagus | Gratis |
| Lifecycle | Standard → IA (30h) → Glacier (90h) | Menurunkan biaya |
| Bucket policy | Menolak koneksi non-HTTPS | Gratis |
| Public access block | Backup tidak akan pernah publik | Gratis |
| IAM user + policy | Kredensial paling terbatas untuk VPS | Gratis |

Total realistis: **di bawah $0.10 per bulan** untuk dataset 80 MB.

---

## Langkah 0 — Sebelum ada akun AWS

Yang bisa dikerjakan sekarang, tanpa kartu:

```bash
cd ~/ark
mkdir -p terraform
# salin folder terraform/backup ke sini
cd terraform/backup
terraform init      # ini butuh internet, tapi tidak butuh kredensial AWS
terraform validate  # cek konfigurasi
terraform fmt       # rapikan format
```

`terraform init` dan `validate` **tidak memerlukan akun AWS**. Jadi kamu bisa
memastikan kodenya benar sekarang juga.

---

## Langkah 1 — Setelah akun AWS ada

**Pasang pengaman dulu, sebelum membuat apa pun:**

Console → Billing → Budgets → Create budget → Cost budget → $5/bulan →
alert di 50% dan 80%. Jangan lewati langkah ini.

**Buat kredensial admin sementara** untuk Terraform. Di IAM, buat user dengan
policy `AdministratorAccess`, ambil access key-nya, lalu:

```bash
aws configure
# masukkan access key, secret, region ap-southeast-1
```

Catatan: kredensial admin ini **cuma untuk menjalankan Terraform**. Yang
dipakai VPS nanti adalah IAM user terbatas yang dibuat oleh Terraform sendiri.

---

## Langkah 2 — Apply

```bash
cd ~/ark/terraform/backup
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — yang wajib diganti cuma `bucket_name`. Nama bucket
S3 itu **unik secara global di seluruh AWS**, jadi `ark-backups` pasti sudah
dipakai orang. Tambahkan sesuatu yang spesifik.

```bash
terraform plan     # baca dulu, jangan langsung apply
terraform apply
```

`plan` akan menampilkan sekitar 9 resource. Baca sekilas — ini kebiasaan yang
baik, dan di lingkungan produksi bisa menyelamatkanmu.

---

## Langkah 3 — Ambil kredensial untuk VPS

```bash
terraform output bucket_name
terraform output access_key_id
terraform output -raw secret_access_key
```

Masukkan ke `~/ark/.env`:

```bash
ARK_S3_BUCKET=nama-bucket-kamu
ARK_S3_REGION=ap-southeast-1
ARK_S3_PREFIX=backups/
ARK_S3_ACCESS_KEY=AKIA...
ARK_S3_SECRET_KEY=...
```

`.env` sudah masuk `.gitignore`, jadi aman.

---

## Langkah 4 — Sambungkan ke Ansible

Tambahkan di `roles/ark-backup/defaults/main.yml`:

```yaml
# S3 upload — biarkan false sampai bucket-nya ada
ark_s3_enabled: false
ark_s3_bucket: ""
ark_s3_region: ap-southeast-1
ark_s3_prefix: "backups/"
ark_s3_access_key: ""
ark_s3_secret_key: ""
```

Lalu di akhir `roles/ark-backup/tasks/main.yml`, sebelum task Report:

```yaml
- name: Upload the backup to S3
  ansible.builtin.include_tasks: upload_s3.yml
  when: ark_s3_enabled | bool
```

Simpan `upload_s3.yml` di `roles/ark-backup/tasks/`.

Untuk membaca nilai dari `.env`, tambahkan di `backup.yml`:

```yaml
- name: Back up the Ark demo stack
  hosts: production
  gather_facts: true
  vars_files:
    - vars/s3.yml      # file ini di-gitignore, isinya kredensial
  roles:
    - ark-backup
```

Install AWS CLI di VPS:

```bash
sudo apt install -y awscli
```

Lalu aktifkan dan uji:

```bash
ansible-playbook backup.yml -e ark_s3_enabled=true
```

---

## Keputusan desain yang perlu kamu pahami

**Kenapa IAM user, bukan role.** VPS-mu bukan EC2, jadi tidak bisa memakai
instance profile. Terpaksa pakai kredensial jangka panjang — dan justru karena
itu, membatasinya jadi krusial.

**Kenapa tidak ada izin DeleteObject.** Kalau VPS-mu diretas, penyerang tidak
bisa menghapus riwayat backup. Penghapusan diserahkan ke lifecycle rule, yang
dikendalikan dari sisi AWS, bukan dari VPS. Ini pola yang sama dengan
append-only backup.

**Kenapa manifest diunggah terakhir.** Kalau upload terputus di tengah, tidak
ada manifest — dan restore tidak akan menemukan backup itu. Lebih baik backup
dianggap tidak ada daripada dianggap ada tapi tidak lengkap.

**Kenapa backup terbaru tetap di Standard.** Saat bencana sungguhan, yang kamu
ambil adalah backup terakhir. Menaruhnya di Glacier menghemat beberapa sen
tapi menambah jam pada RTO-mu. Transisi baru dimulai hari ke-30.

**Kenapa versioning aktif.** Skenario yang sering terlupakan: backup gagal
sebagian, menghasilkan arsip rusak, lalu menimpa backup kemarin yang
sebenarnya bagus. Versioning membuat yang lama tetap bisa diambil.

---

## Setelah ini jalan

Update README:

```markdown
- [x] S3 bucket, lifecycle policy and least-privilege IAM via Terraform
```

Dan hapus catatan sementara soal backup masih lokal — karena sejak titik ini,
backup benar-benar bertahan meski VPS-nya hilang.

Minggu 3: pilot light — VPC, launch template, dan Route 53 hosted zone.
