# __Driftsättning av webbserver i AWS__

Uppgiften går ut på att provisionera en EC2-instans och konfigurera en webbserver åt *Novatrix* i *AWS*.

För att uppnå Väl Godkänt nivå skall detta göras automatiserat med kod.

## *__1. Provisionera en EC2-instans och konfigurera en webbserver__*

Först skapas ett "Key Pair" upp som används att man använder för att ansluta till servern via *SSH* / port 22. Detta görs via *AWS* portalen. Om inte nycklen läcker ut så kan man använda samma par under hela *AWS* kursen. Nyckelparet består av en publik nyckel som finns hos *AWS* och en privat som finns på min dator.

![alt text](images/key_pair.png)

Script *V42_novatrix-ec2.sh* tas fram. Scriptet skapar upp en *ec2* instans, *security group*, webbsida och webbsidans innehåll. Scriptet öppnar öppnar *SSH* / port 22 endast för min dators IP-adress och port 80 för inkommande trafik till *Novatrix* hemsida.

Script *V42_novatrix-ec2.sh*:



## *__2. Månadsbudget__*

Månadsbudget är konfigurerad i *AWS* portalen:

![alt text](images/budget.png)

Den varnar (via e-post) för följande:

*Actual cost > 100%*

*Actual cost > 85%*

*Forecasted cost > 100%*

*Forecasted cost > 85%*

## *__3. Dokumentation__*

## *__4. Verifiering__*
