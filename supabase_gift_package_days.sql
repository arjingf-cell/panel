-- Supabase SQL Editor'de bir kez çalıştırın.
-- Mevcut bitiş tarihinin üzerine tam gün ekler ve yalnızca aktif adminlere izin verir.

create or replace function public.gift_artist_package_days(
  p_artist_id bigint,
  p_package_type text,
  p_note text default null,
  p_days integer default 365
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_artist public.artists%rowtype;
  v_entitlement public.release_entitlements%rowtype;
  v_original_entitlement_expiry timestamptz;
  v_base_expiry timestamptz;
  v_new_expiry timestamptz;
begin
  if not exists (
    select 1
    from public.admin_users
    where user_id = auth.uid()
      and active = true
  ) then
    raise exception 'Bu işlem için aktif admin yetkisi gerekli.';
  end if;

  if p_package_type not in ('single', 'yearly', 'label') then
    raise exception 'Geçersiz paket türü: %', p_package_type;
  end if;

  if coalesce(p_days, 0) < 1 then
    raise exception 'Gün sayısı en az 1 olmalıdır.';
  end if;

  select *
  into v_artist
  from public.artists
  where id = p_artist_id
  for update;

  if not found then
    raise exception 'Sanatçı bulunamadı: %', p_artist_id;
  end if;

  select expires_at
  into v_original_entitlement_expiry
  from public.release_entitlements
  where artist_id = p_artist_id
    and status = 'active'
  order by expires_at desc nulls last, created_at desc
  limit 1;

  v_base_expiry := greatest(
    now(),
    coalesce(v_artist.package_expires_at, now()),
    coalesce(v_original_entitlement_expiry, now())
  );

  -- Var olan fonksiyon hak kaydını ve hediye geçmişini oluşturmaya devam eder.
  perform public.gift_artist_package(
    p_artist_id => p_artist_id,
    p_package_type => p_package_type,
    p_note => p_note,
    p_months => greatest(1, ceil(p_days / 30.0)::integer)
  );

  select *
  into v_entitlement
  from public.release_entitlements
  where artist_id = p_artist_id
    and status = 'active'
  order by created_at desc
  limit 1
  for update;

  if v_entitlement.id is null then
    raise exception 'Aktif yayın hakkı oluşturulamadı.';
  end if;

  if p_package_type <> 'single' then
    v_new_expiry := v_base_expiry + make_interval(days => p_days);

    update public.artists
    set
      package_type = p_package_type,
      package_started_at = coalesce(package_started_at, now()),
      package_expires_at = v_new_expiry,
      payment_status = 'paid',
      panel_status = 'active',
      account_status = 'active'
    where id = p_artist_id;

    update public.release_entitlements
    set
      package_type = p_package_type,
      starts_at = coalesce(starts_at, now()),
      expires_at = v_new_expiry,
      status = 'active'
    where id = v_entitlement.id
    returning * into v_entitlement;
  end if;

  return jsonb_build_object(
    'artist_id', p_artist_id,
    'package_type', p_package_type,
    'starts_at', v_entitlement.starts_at,
    'expires_at', coalesce(v_new_expiry, v_entitlement.expires_at),
    'total_credits', v_entitlement.total_credits,
    'remaining_credits', v_entitlement.remaining_credits,
    'unlimited', v_entitlement.unlimited,
    'status', v_entitlement.status
  );
end;
$$;

revoke all on function public.gift_artist_package_days(bigint, text, text, integer) from public;
grant execute on function public.gift_artist_package_days(bigint, text, text, integer) to authenticated;

notify pgrst, 'reload schema';
