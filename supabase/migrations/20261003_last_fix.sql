-- ここだよ：友だちとの部屋ごとに、各自の「最後の居場所」を1つだけ残す（暗号文のみ）。
-- 中身は2台の端末だけが持つ鍵で暗号化してあり、サーバーは読めない。
-- 直接は誰も読み書きできない（RLSを有効にし、ポリシーを置かない）。関数 lastfix だけが触る。
create table public.last_fix (
  room text not null check (room ~ '^[0-9a-f]{32}$'),
  sender text not null check (sender ~ '^[0-9a-f]{16}$'),
  blob text not null check (length(blob) <= 1000),
  updated_at timestamptz not null default now(),
  primary key (room, sender)
);
alter table public.last_fix enable row level security;
comment on table public.last_fix is 'ここだよ: 部屋ごと・人ごとの最後の居場所（AES-GCMの暗号文のみ）。関数 lastfix 専用';
