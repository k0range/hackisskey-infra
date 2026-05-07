create role misskey login password '{{ postgres_password }}';

alter database misskey owner to misskey;
