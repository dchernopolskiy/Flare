(Not so) Extremely simple (anymore) job posting monitoring tool for Microsoft (now also TikTok, Snap, Meta). 
Displays jobs from the https://careers.microsoft.com/ for the past 24 hours, sends a notification when a new job posting is created.
New update now allows you to paste a careers page link, automatically scan the site and detect the ATS that the company uses, adding it to the list of job sources to scan. Greenhouse, Ashby, Lever, Workday ATS boards are fully supported. V1 also brings in the functionality to properly scrape Meta's GraphQL api and had been tested successfully so far.
Search is performed using the job title and location.

Current backlog: implement more ATS boards, address some performance issues, unify addition of new fetchers (so I don't have to add a new fetcher in 15 different places), but other than that it performs exactly what I needed for myself.

Compile in xcode and run. Bundled version may or may not be coming in the future. 

<p align="center">
<img width="1722" height="1047" alt="image" src="https://github.com/user-attachments/assets/534c9e5c-5dab-4a6e-a742-d111f1d4ed44" />
</p>

<p align="center">
<img width="722" height="602" alt="image" src="https://github.com/user-attachments/assets/a6da55a8-74ec-4b9b-8fab-8e8e1909f49f" />
</p>

<p align="center">
<img width="1724" height="1047" alt="image" src="https://github.com/user-attachments/assets/01205f66-6c1f-40b6-bde5-19a6ac1356e1" />
</p>
