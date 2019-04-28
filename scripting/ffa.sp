#include <sdkhooks>
#include <tf2_stocks>

#define TRIGGER_PHYSICS_OBJECTS 				(1 << 3)
#define TRIGGER_PHYSICS_DEBRIS 					(1 << 8)

#pragma newdecls required

bool
	g_bBackStabbed[MAXPLAYERS + 1];

static Handle
	g_hFlameEntities;
static int
	g_iUserIdLastTrace;
static float
	g_flTimeLastTrace;

static const char g_sProjectileClasses[][] = 
{
	"tf_projectile_rocket", 
	"tf_projectile_sentryrocket",
	"tf_projectile_arrow",
	"tf_projectile_stun_ball",
	"tf_projectile_cleaver",
	"tf_projectile_ball_ornament",
	"tf_projectile_energy_ball",
	"tf_projectile_energy_ring",
	"tf_projectile_flare",
	"tf_projectile_jar",
	"tf_projectile_jar_milk",
	"tf_projectile_pipe",
	"tf_projectile_pipe_remote",
	"tf_projectile_throwable_breadmonster",
	"tf_projectile_throwable_brick",
	"tf_projectile_throwable",
	"tf_projectile_healing_bolt",
	"tf_projectile_syringe"
};

static char g_strPlayerLagCompensationWeapons[][] = 
{
	"tf_weapon_sniperrifle",
	"tf_weapon_sniperrifle_decap",
	"tf_weapon_sniperrifle_classic"
};

enum
{
	FlameEntData_EntRef = 0,
	FlameEntData_LastHitEntRef,
	FlameEntData_MaxStats
};

public void OnPluginStart()
{
	SetConVarInt(FindConVar("mp_friendlyfire"), 1, true, false);
	SetConVarInt(FindConVar("tf_avoidteammates_pushaway"), 0, true, false);
	SetConVarInt(FindConVar("tf_avoidteammates"), 0, true, false);
	
	AddTempEntHook("TFBlood", TempEntHook_Blood);
	AddTempEntHook("World Decal", TempEntHook_Decal);
	AddTempEntHook("Entity Decal", TempEntHook_Decal);
	
	g_hFlameEntities = CreateArray(FlameEntData_MaxStats);
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_death", Event_PlayerDeathPre, EventHookMode_Pre);
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if (IsClientInGame(iClient))
        {
			SDKHook(iClient, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
			SDKHook(iClient, SDKHook_PreThinkPost, FriendlyPushApart);
        }
    }
}

public void OnClientPutInServer(int iClient)
{
	SDKHook(iClient, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
	SDKHook(iClient, SDKHook_PreThinkPost, FriendlyPushApart);
}

public Action Event_PlayerSpawn(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (IsPlayerAlive(iClient) && GetClientTeam(iClient) != 0 && GetClientTeam(iClient) != 1)
	{
		float flPos[3];
		GetClientAbsOrigin(iClient, flPos);
		
		float flAng[3];
		GetClientAbsAngles(iClient, flAng);
		
		ChangeClientTeam_Safe(iClient, 0);
		TF2_RespawnPlayer(iClient);
		
		TeleportEntity(iClient, flPos, flAng, NULL_VECTOR);
	}
}

public Action Event_PlayerDeath(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (iClient > 0)
		CreateTimer(0.1, Timer_RespawnPlayer, iClient, _);
}


public Action Timer_RespawnPlayer(Handle hTimer, int iClient)
{
	ChangeClientTeam(iClient, 2);
	TF2_RespawnPlayer(iClient);
}

public Action Event_PlayerDeathPre(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (iClient > 0)
	{
		if (g_bBackStabbed[iClient])
		{
			hEvent.SetInt("customkill", TF_CUSTOM_BACKSTAB);
			g_bBackStabbed[iClient] = false;
		}
	}
	
	return Plugin_Continue;
}

public void OnGameFrame()
{
	for (int i = 0; i < sizeof(g_sProjectileClasses); i++)
	{
		int iEntity = -1;
		while ((iEntity = FindEntityByClassname(iEntity, g_sProjectileClasses[i])) != -1)
		{
			int iThrowerOffset = FindDataMapInfo(iEntity, "m_hThrower");
			bool bChangeProjectileTeam = false;
			
			int iOwnerEntity = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
			if (IsValidClient(iOwnerEntity))
			{
				bChangeProjectileTeam = true;
			}
			
			else if (iThrowerOffset != -1)
			{
				iOwnerEntity = GetEntDataEnt2(iEntity, iThrowerOffset);
				if (IsValidClient(iOwnerEntity))
				{
					bChangeProjectileTeam = true;
				}
			}
			
			if (bChangeProjectileTeam)
			{
				SetEntProp(iEntity, Prop_Data, "m_iInitialTeamNum", 3);
				SetEntProp(iEntity, Prop_Send, "m_iTeamNum", 3);
			}
		}
	}
	
	static float flMins[3] = { -6.0, ... };
	static float flMaxs[3] = { 6.0, ... };
	
	float flOrigin[3];
	Handle hTrace = INVALID_HANDLE;
	
	int iEntity = -1;
	int iOwnerEntity = INVALID_ENT_REFERENCE; 
	int iHitEntity = INVALID_ENT_REFERENCE;
	
	while ((iEntity = FindEntityByClassname(iEntity, "tf_flame")) != -1)
	{
		iOwnerEntity = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
		if (IsValidEdict(iOwnerEntity))
		{
			iOwnerEntity = GetEntPropEnt(iOwnerEntity, Prop_Data, "m_hOwnerEntity");
		}
		
		if (IsValidClient(iOwnerEntity))
		{
			GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", flOrigin);
			
			hTrace = TR_TraceHullFilterEx(flOrigin, flOrigin, flMins, flMaxs, MASK_PLAYERSOLID, TraceRayDontHitEntity, iOwnerEntity);
			iHitEntity = TR_GetEntityIndex(hTrace);
			CloseHandle(hTrace);
			
			if (IsValidEntity(iHitEntity))
			{
				int iEntRef = EntIndexToEntRef(iEntity);
				
				int iIndex = FindValueInArray(g_hFlameEntities, iEntRef);
				if (iIndex != -1)
				{
					int iLastHitEnt = EntRefToEntIndex(GetArrayCell(g_hFlameEntities, iIndex, FlameEntData_LastHitEntRef));
				
					if (iHitEntity != iLastHitEnt)
					{
						SetArrayCell(g_hFlameEntities, iIndex, EntIndexToEntRef(iHitEntity), FlameEntData_LastHitEntRef);
						OnFlameEntityStartTouchPost(iEntity, iHitEntity);
					}
				}
			}
		}
	}
}

public void OnEntityCreated(int iEntity, const char[] sClassname)
{
	if (StrEqual(sClassname, "tf_flame", false))
	{
		int iIndex = PushArrayCell(g_hFlameEntities, EntIndexToEntRef(iEntity));
		if (iIndex != -1)
		{
			SetArrayCell(g_hFlameEntities, iIndex, INVALID_ENT_REFERENCE, FlameEntData_LastHitEntRef);
		}
	}
	
	else
	{
		for (int i = 0; i < sizeof(g_sProjectileClasses); i++)
		{
			if (StrEqual(sClassname, g_sProjectileClasses[i], false))
			{
				SDKHook(iEntity, SDKHook_Spawn, Hook_ProjectileSpawn);
				SDKHook(iEntity, SDKHook_SpawnPost, Hook_ProjectileSpawnPost);
				break;
			}
		}
	}
}

public void OnEntityDestroyed(int iEntity)
{
	char sClassname[64];
	GetEntityClassname(iEntity, sClassname, sizeof(sClassname));
	
	if (StrEqual(sClassname, "tf_flame", false))
	{
		int iEntRef = EntIndexToEntRef(iEntity);
		
		int iIndex = FindValueInArray(g_hFlameEntities, iEntRef);
		if (iIndex != -1)
		{
			RemoveFromArray(g_hFlameEntities, iIndex);
		}
	}
}

public Action TF2_CalcIsAttackCritical(int iClient, int iWeapon, char[] sWeaponName, bool &result)
{
	bool bNeedsManualDamage = false;
	for (int i = 0; i < sizeof(g_strPlayerLagCompensationWeapons); i++)
	{
		if (StrEqual(sWeaponName, g_strPlayerLagCompensationWeapons[i], false))
		{
			bNeedsManualDamage = true;
			break;
		}
	}
	
	if (bNeedsManualDamage)
	{
		float flStartPos[3];
		GetClientEyePosition(iClient, flStartPos);
		
		float flEyeAng[3];
		GetClientEyeAngles(iClient, flEyeAng);
		
		Handle hTrace = TR_TraceRayFilterEx(flStartPos, flEyeAng, MASK_SHOT, RayType_Infinite, TraceRayDontHitEntity, iClient);
		int iHitEntity = TR_GetEntityIndex(hTrace);
		int iHitGroup = TR_GetHitGroup(hTrace);
		CloseHandle(hTrace);
		
		if (IsValidClient(iHitEntity))
		{
			if (GetClientTeam(iHitEntity) == GetClientTeam(iClient))
			{
				float flChargedDamage = GetEntPropFloat(iWeapon, Prop_Send, "m_flChargedDamage");
				if (flChargedDamage < 50.0) flChargedDamage = 50.0;
				int iDamageType = DMG_BULLET;
				
				if (IsClientCritBoosted(iClient))
				{
					result = true;
					iDamageType |= DMG_ACID;
				}
				else if (iHitGroup == 1)
				{
					if (StrEqual(sWeaponName, "tf_weapon_sniperrifle_classic", false))
					{
						if (flChargedDamage >= 150.0)
						{
							result = true;
							iDamageType |= DMG_ACID;
						}
					}
					else
					{
						if (TF2_IsPlayerInCondition(iClient, TFCond_Zoomed))
						{
							result = true;
							iDamageType |= DMG_ACID;
						}
					}
				}
				
				SDKHooks_TakeDamage(iHitEntity, iClient, iClient, flChargedDamage, iDamageType);
				return Plugin_Changed;
			}
		}
	}
	
	return Plugin_Continue;
}

public Action Hook_OnTakeDamage(int iVictim, int &iAttacker, int &iInflictor, float &flDamage, int &iDamageType, int &iWeapon, float flDamageForce[3], float flDamagePosition[3], int iDamageCustom)
{
	if (iAttacker != iVictim && IsValidClient(iAttacker))
	{
		if (iAttacker == iInflictor)
		{
			if (IsValidEdict(iWeapon))
			{
				char sWeaponClass[64];
				GetEdictClassname(iWeapon, sWeaponClass, sizeof(sWeaponClass));
				
				if ((StrEqual(sWeaponClass, "tf_weapon_knife", false) || (TF2_GetPlayerClass(iAttacker) == TFClass_Spy && StrEqual(sWeaponClass, "saxxy", false))) && (iDamageCustom != TF_CUSTOM_TAUNT_FENCING))
				{
					float flMyPos[3];
					GetClientAbsOrigin(iVictim, flMyPos);
					
					float flHisPos[3];
					GetClientAbsOrigin(iAttacker, flHisPos);
					
					float flMyDirection[3];
					GetClientEyeAngles(iVictim, flMyDirection);
					
					GetAngleVectors(flMyDirection, flMyDirection, NULL_VECTOR, NULL_VECTOR);
					NormalizeVector(flMyDirection, flMyDirection);
					
					ScaleVector(flMyDirection, 32.0);
					AddVectors(flMyDirection, flMyPos, flMyDirection);
					
					float p[3];
					MakeVectorFromPoints(flMyPos, flHisPos, p);
					
					float s[3];
					MakeVectorFromPoints(flMyPos, flMyDirection, s);
					
					if (GetVectorDotProduct(p, s) <= 0.0)
					{
						flDamage = float(GetEntProp(iVictim, Prop_Send, "m_iHealth")) * 2.0;
						
						Handle hCvar = FindConVar("tf_weapon_criticals");
						if (hCvar != INVALID_HANDLE && GetConVarBool(hCvar)) iDamageType |= DMG_ACID;
						
						g_bBackStabbed[iVictim] = true;
						return Plugin_Changed;
					}
				}
			}
		}
	}
	
	return Plugin_Continue;
}

public Action Hook_ProjectileSpawn(int iEntity)
{
	char sClass[64];
	GetEntityClassname(iEntity, sClass, sizeof(sClass));
	
	int iThrowerOffset = FindDataMapInfo(iEntity, "m_hThrower");
	int iOwnerEntity = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
	
	if (iOwnerEntity == -1 && iThrowerOffset != -1)
	{
		iOwnerEntity = GetEntDataEnt2(iEntity, iThrowerOffset);
	}
	
	if (IsValidClient(iOwnerEntity))
	{
		SetEntProp(iEntity, Prop_Data, "m_iInitialTeamNum", 3);
		SetEntProp(iEntity, Prop_Send, "m_iTeamNum", 3);
	}
	
	return Plugin_Continue;
}

public void Hook_ProjectileSpawnPost(int iEntity)
{
	char sClass[64];
	GetEntityClassname(iEntity, sClass, sizeof(sClass));
	
	int iThrowerOffset = FindDataMapInfo(iEntity, "m_hThrower");
	int iOwnerEntity = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
	
	if (iOwnerEntity == -1 && iThrowerOffset != -1)
	{
		iOwnerEntity = GetEntDataEnt2(iEntity, iThrowerOffset);
	}
}

static void OnFlameEntityStartTouchPost(int flame, int iClient)
{
	if (IsValidClient(iClient))
	{
		int iFlamethrower = GetEntPropEnt(flame, Prop_Data, "m_hOwnerEntity");
		if (IsValidEdict(iFlamethrower))
		{
			int iOwnerEntity = GetEntPropEnt(iFlamethrower, Prop_Data, "m_hOwnerEntity");
			if (iOwnerEntity != iClient && IsValidClient(iOwnerEntity))
			{
				TF2_IgnitePlayer(iClient, iOwnerEntity);
				SDKHooks_TakeDamage(iClient, iOwnerEntity, iOwnerEntity, 7.0, IsClientCritBoosted(iOwnerEntity) ? (DMG_BURN | DMG_PREVENT_PHYSICS_FORCE | DMG_ACID) : DMG_BURN | DMG_PREVENT_PHYSICS_FORCE); 
			}
		}
	}
}

public bool TraceRayDontHitEntity(int iEntity, int mask, any data)
{
	if (iEntity == data)
		return false;
		
	if (IsValidEdict(iEntity))
	{
		char sClass[64];
		GetEntityNetClass(iEntity, sClass, sizeof(sClass));
		
		if (StrEqual(sClass, "CTFBaseBoss"))
			return false;
	}
	
	return true;
}

public Action TempEntHook_Blood(const char[] sTE_Name, int[] iPlayers, int iNumPlayers, float flDelay)
{
	if (IsValidClient(TE_ReadNum("entindex")))
		return Plugin_Stop;
		
	return Plugin_Continue;
}

public Action Hook_PlayerTraceAttack(int iVictim, int &iAttacker, int &iInflictor, float &flDamage, int &iDamageType, int &ammotype, int hitbox, int hitgroup)
{
	if (IsValidClient(iVictim))
	{
		g_iUserIdLastTrace = GetClientUserId(iVictim);
		g_flTimeLastTrace = GetEngineTime();
	}
	
	return Plugin_Continue;
}

public Action TempEntHook_Decal(const char[] sTE_Name, int[] iPlayers, int iNumPlayers, float flDelay)
{
	if (IsValidClient(GetClientOfUserId(g_iUserIdLastTrace)))
	{
		if (g_flTimeLastTrace != 0.0 && GetEngineTime() - g_flTimeLastTrace < 0.1)
			return Plugin_Stop;
	}

	return Plugin_Continue;
}

stock int FindStringIndex2(int tableidx, const char[] str)
{
	char buf[1024];
	
	int numStrings = GetStringTableNumStrings(tableidx);
	for (int i=0; i < numStrings; i++) {
		ReadStringTable(tableidx, i, buf, sizeof(buf));
		
		if (StrEqual(buf, str)) {
			return i;
		}
	}
	
	return INVALID_STRING_INDEX;
}

stock bool IsClientCritBoosted(int iClient)
{
	if (TF2_IsPlayerInCondition(iClient, TFCond_Kritzkrieged) ||
		TF2_IsPlayerInCondition(iClient, TFCond_HalloweenCritCandy) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritCanteen) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritOnFirstBlood) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritOnWin) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritOnFlagCapture) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritOnKill) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritOnDamage) ||
		TF2_IsPlayerInCondition(iClient, TFCond_CritMmmph))
	{
		return true;
	}
	
	int iActiveWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
	if (IsValidEdict(iActiveWeapon))
	{
		char sNetClass[64];
		GetEntityNetClass(iActiveWeapon, sNetClass, sizeof(sNetClass));
		
		if (StrEqual(sNetClass, "CTFFlameThrower"))
		{
			if (GetEntProp(iActiveWeapon, Prop_Send, "m_bCritFire"))
				return true;
				
			int iItemDef = GetEntProp(iActiveWeapon, Prop_Send, "m_iItemDefinitionIndex");
			if (iItemDef == 594 && TF2_IsPlayerInCondition(iClient, TFCond_CritMmmph))
				return true;
		}
		
		else if (StrEqual(sNetClass, "CTFMinigun"))
		{
			if (GetEntProp(iActiveWeapon, Prop_Send, "m_bCritShot"))
				return true;
		}
	}
	
	return false;
}

stock int PrecacheParticleSystem(const char[] sParticleSystem)
{
	static int iParticleEffectNames = INVALID_STRING_TABLE;
	if (iParticleEffectNames == INVALID_STRING_TABLE) {
		if ((iParticleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE) {
			return INVALID_STRING_INDEX;
		}
	}
	
	int iIndex = FindStringIndex2(iParticleEffectNames, sParticleSystem);
	if (iIndex == INVALID_STRING_INDEX)
	{
		int iNumStrings = GetStringTableNumStrings(iParticleEffectNames);
		if (iNumStrings >= GetStringTableMaxStrings(iParticleEffectNames))
			return INVALID_STRING_INDEX;
			
		AddToStringTable(iParticleEffectNames, sParticleSystem);
		iIndex = numStrings;
	}
	
	return iIndex;
}

stock void TE_SetupTFParticleEffect(int iParticleSystemIndex, const float flOrigin[3], const float flStart[3]=NULL_VECTOR, int iAttachType=0, int iEntIndex=-1, int iAttachmentPointIndex=0, bool bControlPoint1=false, const float flControlPoint1Offset[3] = NULL_VECTOR)
{
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", flOrigin[0]);
	TE_WriteFloat("m_vecOrigin[1]", flOrigin[1]);
	TE_WriteFloat("m_vecOrigin[2]", flOrigin[2]);
	TE_WriteFloat("m_vecStart[0]", flStart[0]);
	TE_WriteFloat("m_vecStart[1]", flStart[1]);
	TE_WriteFloat("m_vecStart[2]", flStart[2]);
	TE_WriteNum("m_iParticleSystemIndex", iParticleSystemIndex);
	TE_WriteNum("m_iAttachType", iAttachType);
	TE_WriteNum("entindex", iEntIndex);
	TE_WriteNum("m_iAttachmentPointIndex", iAttachmentPointIndex);
	TE_WriteNum("m_bControlPoint1", bControlPoint1);
	TE_WriteFloat("m_ControlPoint1.m_vecOffset[0]", flControlPoint1Offset[0]);
	TE_WriteFloat("m_ControlPoint1.m_vecOffset[1]", flControlPoint1Offset[1]);
	TE_WriteFloat("m_ControlPoint1.m_vecOffset[2]", flControlPoint1Offset[2]);
}

public void FriendlyPushApart(int iClient)
{    
    // if (!bFriendlyFire)
    // {
    //     // Technically this code should never be reached because we unhook it during CvarChange
    //     SDKUnhook(iClient, SDKHook_PreThinkPost, FriendlyPushApart);
    //     return;
    // }
	
    if (IsPlayerAlive(iClient) && IsPlayerStuck(iClient))       // If a player is stuck in a player, push them apart
		PushClientsApart(iClient, TR_GetEntityIndex());         // Temporarily remove collision while we push apart
		
    else
		SetEntProp(iClient, Prop_Send, "m_CollisionGroup", 5);  // Same collision as normal
}

stock bool IsPlayerStuck(int iEntity)
{
	float vecMin[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecMins", vecMin);
	
	float vecMax[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecMaxs", vecMax);
	
	float vecOrigin[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", vecOrigin);
	
	TR_TraceHullFilter(vecOrigin, vecOrigin, vecMin, vecMax, MASK_SOLID, TraceRayPlayerOnly, iEntity);
	return (TR_DidHit());
}

public bool TraceRayPlayerOnly(int iEntity, int iMask, any iData)
{
    return (IsValidClient(iEntity) && IsValidClient(iData) && iEntity != iData);
}

stock void PushClientsApart(int iClient1, int iClient2)
{
	SetEntProp(iClient1, Prop_Send, "m_CollisionGroup", 2);     // No collision with players and certain projectiles
	SetEntProp(iClient2, Prop_Send, "m_CollisionGroup", 2);
	
	float vOrigin1[3];
	GetEntPropVector(iClient1, Prop_Send, "m_vecOrigin", vOrigin1);
	
	float vOrigin2[3];
	GetEntPropVector(iClient2, Prop_Send, "m_vecOrigin", vOrigin2);
	
	float vVel[3];
	MakeVectorFromPoints(vOrigin1, vOrigin2, vVel);
	NormalizeVector(vVel, vVel);
	ScaleVector(vVel, -15.0);               // Set to 15.0 for a black hole effect
	
	vVel[1] += 0.1;                         // This is just a safeguard for sm_tele
	vVel[2] = 0.0;                          // Negate upwards push. += 280.0; for extra upwards push (can have sort of a fan/vent effect)
	
	int iBaseVelocityOffset = FindSendPropInfo("CBasePlayer","m_vecBaseVelocity");
	SetEntDataVector(iClient1, iBaseVelocityOffset, vVel, true);
}

stock bool IsValidClient(int iClient)
{
	return view_as<bool>((iClient > 0 && iClient <= MaxClients && IsClientInGame(iClient)));
}

stock void ChangeClientTeam_Safe(int iClient, int iTeam)
{
    int EntProp = GetEntProp(iClient, Prop_Send, "m_lifeState");
    SetEntProp(iClient, Prop_Send, "m_lifeState", 2);
    ChangeClientTeam(iClient, iTeam);
    SetEntProp(iClient, Prop_Send, "m_lifeState", EntProp);
}

public Plugin myinfo =
{
	name 		= 	"Titan.TF - Free For All",
	author 		= 	"myst",
	version 	= 	"1.0"
};