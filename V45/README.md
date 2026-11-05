# __Databas och lagring__

Repository: https://github.com/03timnor/AWS_MOV25

*Tim Noreliusson Lingestedt, 2026-11-05*

Veckans uppgift innefattar att börja med *WordPress*-stacken. *WordPress* behöver en databas och lagring aom kopplas ihop med webbservern för att fungera.

Väl Godkänt delen av uppgiften gåt ut på att göra motiverade val av databas och lagringsnivåer, säkra åtkomsten och att miljön skall skapas med kod.

## *__1. Provisionera miljön__*



## *__2. Dokumentation__*



## *__3. Verifiering__*

### *__Webbsidan / WordPress fungerar och nås__*

![alt text](pictures/wordpress_user.png)

![alt text](pictures/wordpress_admin.png)

### *__Automatisk backup av databas__*

![alt text](pictures/automated_backup.png)

### *__WordPress-filerna finns på EFS__*

![alt text](pictures/efs_wordpress.png)

### *__Delad lagring i de privata subnäten__*

![alt text](pictures/efs.png)

### *__Databas krypterad och privat__*

![alt text](pictures/rds_database.png)

### *__Backuper av databas och filer i S3__*

![alt text](pictures/s3_backup.png)

![alt text](pictures/s3_backup_db.png)

![alt text](pictures/s3_backup_filer.png)

### *__Backuper raderas efter 14 dagar__*

![alt text](pictures/s3_lifecycle_1.png)

![alt text](pictures/s3_lifecycle_2.png)

### *__Verifiering, alla tester OK__*

![alt text](pictures/verify.png)