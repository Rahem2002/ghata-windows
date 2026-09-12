create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.exchange_entries
  where exchange_id in (
    select id from public.exchanges
    where user_id = v_user_id
  );

  delete from public.transactions where user_id = v_user_id;
  delete from public.exchanges where user_id = v_user_id;
  delete from public.customers where user_id = v_user_id;
  delete from public.staff_members where owner_id = v_user_id;
  delete from public.profiles where id = v_user_id;

  delete from auth.users where id = v_user_id;
end;
$$;

revoke all on function public.delete_my_account() from public;
revoke all on function public.delete_my_account() from anon;
grant execute on function public.delete_my_account() to authenticated;
