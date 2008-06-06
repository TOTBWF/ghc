%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

Typechecking class declarations

\begin{code}
module TcClassDcl ( tcClassSigs, tcClassDecl2, 
		    getGenericInstances, 
		    MethodSpec, tcMethodBind, mkMethId,
		    tcAddDeclCtxt, badMethodErr, badATErr, omittedATWarn
		  ) where

#include "HsVersions.h"

import HsSyn
import RnHsSyn
import RnExpr
import RnEnv
import Inst
import InstEnv
import TcEnv
import TcBinds
import TcHsType
import TcSimplify
import TcUnify
import TcMType
import TcType
import TcRnMonad
import Generics
import Class
import TyCon
import Type
import MkId
import Id
import Name
import Var
import NameEnv
import NameSet
import OccName
import RdrName
import Outputable
import PrelNames
import DynFlags
import ErrUtils
import Util
import Unique
import ListSetOps
import SrcLoc
import Maybes
import List
import BasicTypes
import Bag
import FastString

import Control.Monad
\end{code}


Dictionary handling
~~~~~~~~~~~~~~~~~~~
Every class implicitly declares a new data type, corresponding to dictionaries
of that class. So, for example:

	class (D a) => C a where
	  op1 :: a -> a
	  op2 :: forall b. Ord b => a -> b -> b

would implicitly declare

	data CDict a = CDict (D a)	
			     (a -> a)
			     (forall b. Ord b => a -> b -> b)

(We could use a record decl, but that means changing more of the existing apparatus.
One step at at time!)

For classes with just one superclass+method, we use a newtype decl instead:

	class C a where
	  op :: forallb. a -> b -> b

generates

	newtype CDict a = CDict (forall b. a -> b -> b)

Now DictTy in Type is just a form of type synomym: 
	DictTy c t = TyConTy CDict `AppTy` t

Death to "ExpandingDicts".


%************************************************************************
%*									*
		Type-checking the class op signatures
%*									*
%************************************************************************

\begin{code}
tcClassSigs :: Name	    		-- Name of the class
	    -> [LSig Name]
	    -> LHsBinds Name
	    -> TcM [TcMethInfo]

type TcMethInfo = (Name, DefMeth, Type)	-- A temporary intermediate, to communicate 
					-- between tcClassSigs and buildClass
tcClassSigs clas sigs def_methods
  = do { dm_env <- checkDefaultBinds clas op_names def_methods
       ; mapM (tcClassSig dm_env) op_sigs }
  where
    op_sigs  = [sig | sig@(L _ (TypeSig _ _))       <- sigs]
    op_names = [n   |     (L _ (TypeSig (L _ n) _)) <- op_sigs]


checkDefaultBinds :: Name -> [Name] -> LHsBinds Name -> TcM (NameEnv Bool)
  -- Check default bindings
  -- 	a) must be for a class op for this class
  --	b) must be all generic or all non-generic
  -- and return a mapping from class-op to Bool
  --	where True <=> it's a generic default method
checkDefaultBinds clas ops binds
  = do dm_infos <- mapM (addLocM (checkDefaultBind clas ops)) (bagToList binds)
       return (mkNameEnv dm_infos)

checkDefaultBind :: Name -> [Name] -> HsBindLR Name Name -> TcM (Name, Bool)
checkDefaultBind clas ops (FunBind {fun_id = L _ op, fun_matches = MatchGroup matches _ })
  = do {  	-- Check that the op is from this class
	checkTc (op `elem` ops) (badMethodErr clas op)

   	-- Check that all the defns ar generic, or none are
    ;	checkTc (all_generic || none_generic) (mixedGenericErr op)

    ;	return (op, all_generic)
    }
  where
    n_generic    = count (isJust . maybeGenericMatch) matches
    none_generic = n_generic == 0
    all_generic  = matches `lengthIs` n_generic
checkDefaultBind _ _ b = pprPanic "checkDefaultBind" (ppr b)


tcClassSig :: NameEnv Bool		-- Info about default methods; 
	   -> LSig Name
	   -> TcM TcMethInfo

tcClassSig dm_env (L loc (TypeSig (L _ op_name) op_hs_ty))
  = setSrcSpan loc $ do
    { op_ty <- tcHsKindedType op_hs_ty	-- Class tyvars already in scope
    ; let dm = case lookupNameEnv dm_env op_name of
		Nothing    -> NoDefMeth
		Just False -> DefMeth
		Just True  -> GenDefMeth
    ; return (op_name, dm, op_ty) }
tcClassSig _ s = pprPanic "tcClassSig" (ppr s)
\end{code}


%************************************************************************
%*									*
		Class Declarations
%*									*
%************************************************************************

\begin{code}
tcClassDecl2 :: LTyClDecl Name		-- The class declaration
	     -> TcM (LHsBinds Id, [Id])

tcClassDecl2 (L loc (ClassDecl {tcdLName = class_name, tcdSigs = sigs, 
				tcdMeths = default_binds}))
  = recoverM (return (emptyLHsBinds, []))	$
    setSrcSpan loc		   		$ do
    clas <- tcLookupLocatedClass class_name

	-- We make a separate binding for each default method.
	-- At one time I used a single AbsBinds for all of them, thus
	-- AbsBind [d] [dm1, dm2, dm3] { dm1 = ...; dm2 = ...; dm3 = ... }
	-- But that desugars into
	--	ds = \d -> (..., ..., ...)
	--	dm1 = \d -> case ds d of (a,b,c) -> a
	-- And since ds is big, it doesn't get inlined, so we don't get good
	-- default methods.  Better to make separate AbsBinds for each
    let
	(tyvars, _, _, op_items) = classBigSig clas
	rigid_info  		 = ClsSkol clas
	origin 			 = SigOrigin rigid_info
	prag_fn			 = mkPragFun sigs
	sig_fn			 = mkTcSigFun sigs
	clas_tyvars		 = tcSkolSigTyVars rigid_info tyvars
	tc_dm			 = tcDefMeth origin clas clas_tyvars
					     default_binds sig_fn prag_fn

	dm_sel_ids		 = [sel_id | (sel_id, DefMeth) <- op_items]
	-- Generate code for polymorphic default methods only
	-- (Generic default methods have turned into instance decls by now.)
	-- This is incompatible with Hugs, which expects a polymorphic 
	-- default method for every class op, regardless of whether or not 
	-- the programmer supplied an explicit default decl for the class.  
	-- (If necessary we can fix that, but we don't have a convenient Id to hand.)

    (defm_binds, dm_ids_s) <- mapAndUnzipM tc_dm dm_sel_ids
    return (listToBag defm_binds, concat dm_ids_s)
tcClassDecl2 d = pprPanic "tcClassDecl2" (ppr d)
    
tcDefMeth :: InstOrigin -> Class -> [TyVar] -> LHsBinds Name
          -> TcSigFun -> TcPragFun -> Id
          -> TcM (LHsBindLR Id Var, [Id])
tcDefMeth origin clas tyvars binds_in sig_fn prag_fn sel_id
  = do	{ dm_name <- lookupTopBndrRn (mkDefMethRdrName sel_id)
	; let	inst_tys    = mkTyVarTys tyvars
		dm_ty       = idType sel_id	-- Same as dict selector!
	        cls_pred    = mkClassPred clas inst_tys
		local_dm_id = mkDefaultMethodId dm_name dm_ty

	; loc <- getInstLoc origin
	; this_dict <- newDictBndr loc cls_pred
	; (_, meth_id) <- mkMethId origin clas sel_id inst_tys
	; (defm_bind, insts_needed) <- getLIE $
		tcMethodBind origin tyvars [cls_pred] this_dict []
			     sig_fn prag_fn binds_in
			     (sel_id, DefMeth) meth_id
    
	; addErrCtxt (defltMethCtxt clas) $ do
    
        -- Check the context
	{ dict_binds <- tcSimplifyCheck
			        loc
				tyvars
			        [this_dict]
			        insts_needed

	-- Simplification can do unification
	; checkSigTyVars tyvars
    
	-- Inline pragmas 
	-- We'll have an inline pragma on the local binding, made by tcMethodBind
	-- but that's not enough; we want one on the global default method too
	-- Specialisations, on the other hand, belong on the thing inside only, I think
	; let sel_name	       = idName sel_id
	      inline_prags     = filter isInlineLSig (prag_fn sel_name)
	; prags <- tcPrags meth_id inline_prags

	; let full_bind = AbsBinds  tyvars
		    		    [instToId this_dict]
		    		    [(tyvars, local_dm_id, meth_id, prags)]
		    		    (dict_binds `unionBags` defm_bind)
	; return (noLoc full_bind, [local_dm_id]) }}

mkDefMethRdrName :: Id -> RdrName
mkDefMethRdrName sel_id = mkDerivedRdrName (idName sel_id) mkDefaultMethodOcc
\end{code}


%************************************************************************
%*									*
\subsection{Typechecking a method}
%*									*
%************************************************************************

@tcMethodBind@ is used to type-check both default-method and
instance-decl method declarations.  We must type-check methods one at a
time, because their signatures may have different contexts and
tyvar sets.

\begin{code}
type MethodSpec = (Id, 			-- Global selector Id
		   Id, 			-- Local Id (class tyvars instantiated)
		   LHsBind Name)	-- Binding for the method

tcMethodBind 
	:: InstOrigin
	-> [TcTyVar]		-- Skolemised type variables for the
				--  	enclosing class/instance decl. 
				--  	They'll be signature tyvars, and we
				--  	want to check that they don't get bound
				-- Also they are scoped, so we bring them into scope
				-- Always equal the range of the type envt
	-> TcThetaType		-- Available theta; it's just used for the error message
	-> Inst			-- Current dictionary (this_dict)
	-> [Inst]		-- Other stuff available from context, used to simplify 
				--   constraints from the method body (exclude this_dict)
	-> TcSigFun		-- For scoped tyvars, indexed by sel_name
	-> TcPragFun		-- Pragmas (e.g. inline pragmas), indexed by sel_name
        -> LHsBinds Name	-- Method binding (pick the right one from in here)
	-> ClassOpItem
	-> TcId			-- The method Id
	-> TcM (LHsBinds Id)

tcMethodBind origin inst_tyvars inst_theta 
	     this_dict extra_insts 
	     sig_fn prag_fn meth_binds
	     (sel_id, dm_info) meth_id
  | Just user_bind <- find_bind sel_name meth_name meth_binds
  = 		-- If there is a user-supplied method binding, typecheck it
    tc_method_bind inst_tyvars inst_theta (this_dict:extra_insts) 
		   sig_fn prag_fn
		   sel_id meth_id user_bind

  | otherwise	-- The user didn't supply a method binding, so we have to make 
		-- up a default binding, in a way depending on the default-method info
  = case dm_info of
      NoDefMeth -> do	{ warn <- doptM Opt_WarnMissingMethods		
                        ; warnTc (isInstDecl origin  
				   && warn   -- Warn only if -fwarn-missing-methods
				   && reportIfUnused (getOccName sel_id))
					     -- Don't warn about _foo methods
			         (omittedMethodWarn sel_id) 
			; return (unitBag $ L loc (VarBind meth_id error_rhs)) }

      DefMeth ->   do	{	-- An polymorphic default method
				-- Might not be imported, but will be an OrigName
			  dm_name <- lookupImportedName (mkDefMethRdrName sel_id)
			; dm_id   <- tcLookupId dm_name
				-- Note [Default methods in instances]
			; return (unitBag $ L loc (VarBind meth_id (mk_dm_app dm_id))) }

      GenDefMeth -> ASSERT( isInstDecl origin )	-- We never get here from a class decl
    		    do	{ meth_bind <- mkGenericDefMethBind clas inst_tys sel_id meth_name
			; tc_method_bind inst_tyvars inst_theta (this_dict:extra_insts) 
					 sig_fn prag_fn
					 sel_id meth_id meth_bind }

  where
    meth_name = idName meth_id
    sel_name  = idName sel_id
    loc       = getSrcSpan meth_id
    (clas, inst_tys) = getDictClassTys this_dict

    this_dict_id = instToId this_dict
    error_id     = L loc (HsVar nO_METHOD_BINDING_ERROR_ID) 
    error_id_app = mkLHsWrap (WpTyApp (idType meth_id)) error_id
    error_rhs    = mkHsApp error_id_app $ L loc $
	    	   HsLit (HsStringPrim (mkFastString error_msg))
    error_msg    = showSDoc (hcat [ppr loc, text "|", ppr sel_id ])

    mk_dm_app dm_id	-- dm tys inst_dict
	= mkLHsWrap (WpApp this_dict_id `WpCompose` mkWpTyApps inst_tys) 
		    (L loc (HsVar dm_id))


---------------------------
tc_method_bind :: [TyVar] -> TcThetaType -> [Inst] -> (Name -> Maybe [Name])
               -> (Name -> [LSig Name]) -> Id -> Id -> LHsBind Name
               -> TcRn (LHsBindsLR Id Var)
tc_method_bind inst_tyvars inst_theta avail_insts sig_fn prag_fn
	      sel_id meth_id meth_bind
  = recoverM (return emptyLHsBinds) $
	-- If anything fails, recover returning no bindings.
	-- This is particularly useful when checking the default-method binding of
	-- a class decl. If we don't recover, we don't add the default method to
	-- the type enviroment, and we get a tcLookup failure on $dmeth later.

    	-- Check the bindings; first adding inst_tyvars to the envt
	-- so that we don't quantify over them in nested places

    do	{ let sel_name  = idName sel_id
              meth_name = idName meth_id
              meth_sig_fn name = ASSERT( name == meth_name ) sig_fn sel_name
		-- The meth_bind metions the meth_name, but sig_fn is indexed by sel_name

	; ((meth_bind, mono_bind_infos), meth_lie)
	       <- tcExtendTyVarEnv inst_tyvars      $
	          tcExtendIdEnv [meth_id]           $ -- In scope for tcInstSig
	          addErrCtxt (methodCtxt sel_id)    $
	          getLIE                            $
	          tcMonoBinds [meth_bind] meth_sig_fn Recursive

		-- Now do context reduction.   We simplify wrt both the local tyvars
		-- and the ones of the class/instance decl, so that there is
		-- no problem with
		--	class C a where
		--	  op :: Eq a => a -> b -> a
		--
		-- We do this for each method independently to localise error messages

	; let [(_, Just sig, local_meth_id)] = mono_bind_infos
	      loc = sig_loc sig

	; addErrCtxtM (sigCtxt sel_id inst_tyvars inst_theta (idType meth_id)) $ do
	{ meth_dicts <- newDictBndrs loc (sig_theta sig)
	; let meth_tvs   = sig_tvs sig
              all_tyvars = meth_tvs ++ inst_tyvars
              all_insts  = avail_insts ++ meth_dicts

	; lie_binds <- tcSimplifyCheck loc all_tyvars all_insts meth_lie

	; checkSigTyVars all_tyvars
	
	; prags <- tcPrags meth_id (prag_fn sel_name)
	; let poly_meth_bind = noLoc $ AbsBinds meth_tvs
				  (map instToId meth_dicts)
     				  [(meth_tvs, meth_id, local_meth_id, prags)]
				  (lie_binds `unionBags` meth_bind)

	; return (unitBag poly_meth_bind) }}


---------------------------
mkMethId :: InstOrigin -> Class
	 -> Id -> [TcType]	-- Selector, and instance types
	 -> TcM (Maybe Inst, Id)
	     
-- mkMethId instantiates the selector Id at the specified types
mkMethId origin clas sel_id inst_tys
  = let
	(tyvars,rho) = tcSplitForAllTys (idType sel_id)
	rho_ty	     = ASSERT( length tyvars == length inst_tys )
		       substTyWith tyvars inst_tys rho
	(preds,tau)  = tcSplitPhiTy rho_ty
        first_pred   = ASSERT( not (null preds)) head preds
    in
	-- The first predicate should be of form (C a b)
	-- where C is the class in question
    ASSERT( not (null preds) && 
	    case getClassPredTys_maybe first_pred of
		{ Just (clas1, _tys) -> clas == clas1 ; Nothing -> False }
    )
    if isSingleton preds then do
	-- If it's the only one, make a 'method'
        inst_loc <- getInstLoc origin
        meth_inst <- newMethod inst_loc sel_id inst_tys
        return (Just meth_inst, instToId meth_inst)
    else do
	-- If it's not the only one we need to be careful
	-- For example, given 'op' defined thus:
	--	class Foo a where
	--	  op :: (?x :: String) => a -> a
	-- (mkMethId op T) should return an Inst with type
	--	(?x :: String) => T -> T
	-- That is, the class-op's context is still there.  
	-- BUT: it can't be a Method any more, because it breaks
	-- 	INVARIANT 2 of methods.  (See the data decl for Inst.)
	uniq <- newUnique
	loc <- getSrcSpanM
	let 
	    real_tau = mkPhiTy (tail preds) tau
	    meth_id  = mkUserLocal (getOccName sel_id) uniq real_tau loc

	return (Nothing, meth_id)

---------------------------
-- The renamer just puts the selector ID as the binder in the method binding
-- but we must use the method name; so we substitute it here.  Crude but simple.
find_bind :: Name -> Name 	-- Selector and method name
          -> LHsBinds Name 		-- A group of bindings
	  -> Maybe (LHsBind Name)	-- The binding, with meth_name replacing sel_name
find_bind sel_name meth_name binds
  = foldlBag mplus Nothing (mapBag f binds)
  where 
	f (L loc1 bind@(FunBind { fun_id = L loc2 op_name })) | op_name == sel_name
		 = Just (L loc1 (bind { fun_id = L loc2 meth_name }))
	f _other = Nothing

---------------------------
mkGenericDefMethBind :: Class -> [Type] -> Id -> Name -> TcM (LHsBind Name)
mkGenericDefMethBind clas inst_tys sel_id meth_name
  = 	-- A generic default method
    	-- If the method is defined generically, we can only do the job if the
	-- instance declaration is for a single-parameter type class with
	-- a type constructor applied to type arguments in the instance decl
	-- 	(checkTc, so False provokes the error)
    do	{ checkTc (isJust maybe_tycon)
	 	  (badGenericInstance sel_id (notSimple inst_tys))
	; checkTc (tyConHasGenerics tycon)
	   	  (badGenericInstance sel_id (notGeneric tycon))

	; dflags <- getDOpts
	; liftIO (dumpIfSet_dyn dflags Opt_D_dump_deriv "Filling in method body"
		   (vcat [ppr clas <+> ppr inst_tys,
			  nest 2 (ppr sel_id <+> equals <+> ppr rhs)]))

		-- Rename it before returning it
	; (rn_rhs, _) <- rnLExpr rhs
        ; return (noLoc $ mkFunBind (noLoc meth_name) [mkSimpleMatch [] rn_rhs]) }
  where
    rhs = mkGenericRhs sel_id clas_tyvar tycon

	  -- The tycon is only used in the generic case, and in that
	  -- case we require that the instance decl is for a single-parameter
	  -- type class with type variable arguments:
	  --	instance (...) => C (T a b)
    clas_tyvar  = ASSERT (not (null (classTyVars clas))) head (classTyVars clas)
    Just tycon	= maybe_tycon
    maybe_tycon = case inst_tys of 
			[ty] -> case tcSplitTyConApp_maybe ty of
				  Just (tycon, arg_tys) | all tcIsTyVarTy arg_tys -> Just tycon
				  _    						  -> Nothing
			_ -> Nothing

isInstDecl :: InstOrigin -> Bool
isInstDecl (SigOrigin InstSkol)    = True
isInstDecl (SigOrigin (ClsSkol _)) = False
isInstDecl o                       = pprPanic "isInstDecl" (ppr o)
\end{code}


Note [Default methods]
~~~~~~~~~~~~~~~~~~~~~~~
The default methods for a class are each passed a dictionary for the
class, so that they get access to the other methods at the same type.
So, given the class decl

    class Foo a where
	op1 :: a -> Bool
	op2 :: forall b. Ord b => a -> b -> b -> b

	op1 x = True
	op2 x y z = if (op1 x) && (y < z) then y else z

we get the default methods:

    $dmop1 :: forall a. Foo a => a -> Bool
    $dmop1 = /\a -> \dfoo -> \x -> True

    $dmop2 :: forall a. Foo a => forall b. Ord b => a -> b -> b -> b
    $dmop2 = /\ a -> \ dfoo -> /\ b -> \ dord -> \x y z ->
       		  if (op1 a dfoo x) && (< b dord y z) then y else z

When we come across an instance decl, we may need to use the default methods:

    instance Foo Int where {}

    $dFooInt :: Foo Int
    $dFooInt = MkFoo ($dmop1 Int $dFooInt) 
		     ($dmop2 Int $dFooInt)

Notice that, as with method selectors above, we assume that dictionary
application is curried, so there's no need to mention the Ord dictionary
in the application of $dmop2.

   instance Foo a => Foo [a] where {}

   $dFooList :: forall a. Foo a -> Foo [a]
   $dFooList = /\ a -> \ dfoo_a ->
	      let rec
		op1 = defm.Foo.op1 [a] dfoo_list
		op2 = defm.Foo.op2 [a] dfoo_list
		dfoo_list = MkFoo ($dmop1 [a] dfoo_list)
				  ($dmop2 [a] dfoo_list)
	      in
	      dfoo_list

Note [Default methods in instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this

   class Baz v x where
      foo :: x -> x
      foo y = y

   instance Baz Int Int

From the class decl we get

   $dmfoo :: forall v x. Baz v x => x -> x

Notice that the type is ambiguous.  That's fine, though. The instance decl generates

   $dBazIntInt = MkBaz ($dmfoo Int Int $dBazIntInt)

BUT this does mean we must generate the dictionary translation directly, rather
than generating source-code and type-checking it.  That was the bug ing
Trac #1061. In any case it's less work to generate the translated version!


%************************************************************************
%*									*
\subsection{Extracting generic instance declaration from class declarations}
%*									*
%************************************************************************

@getGenericInstances@ extracts the generic instance declarations from a class
declaration.  For exmaple

	class C a where
	  op :: a -> a
	
	  op{ x+y } (Inl v)   = ...
	  op{ x+y } (Inr v)   = ...
	  op{ x*y } (v :*: w) = ...
	  op{ 1   } Unit      = ...

gives rise to the instance declarations

	instance C (x+y) where
	  op (Inl v)   = ...
	  op (Inr v)   = ...
	
	instance C (x*y) where
	  op (v :*: w) = ...

	instance C 1 where
	  op Unit      = ...


\begin{code}
getGenericInstances :: [LTyClDecl Name] -> TcM [InstInfo] 
getGenericInstances class_decls
  = do	{ gen_inst_infos <- mapM (addLocM get_generics) class_decls
	; let { gen_inst_info = concat gen_inst_infos }

	-- Return right away if there is no generic stuff
	; if null gen_inst_info then return []
	  else do 

	-- Otherwise print it out
	{ dflags <- getDOpts
	; liftIO (dumpIfSet_dyn dflags Opt_D_dump_deriv "Generic instances"
	         (vcat (map pprInstInfoDetails gen_inst_info)))	
	; return gen_inst_info }}

get_generics :: TyClDecl Name -> TcM [InstInfo]
get_generics decl@(ClassDecl {tcdLName = class_name, tcdMeths = def_methods})
  | null generic_binds
  = return [] -- The comon case: no generic default methods

  | otherwise	-- A source class decl with generic default methods
  = recoverM (return [])                                $
    tcAddDeclCtxt decl                                  $ do
    clas <- tcLookupLocatedClass class_name

	-- Group by type, and
	-- make an InstInfo out of each group
    let
	groups = groupWith listToBag generic_binds

    inst_infos <- mapM (mkGenericInstance clas) groups

	-- Check that there is only one InstInfo for each type constructor
  	-- The main way this can fail is if you write
	--	f {| a+b |} ... = ...
	--	f {| x+y |} ... = ...
	-- Then at this point we'll have an InstInfo for each
	--
	-- The class should be unary, which is why simpleInstInfoTyCon should be ok
    let
	tc_inst_infos :: [(TyCon, InstInfo)]
	tc_inst_infos = [(simpleInstInfoTyCon i, i) | i <- inst_infos]

	bad_groups = [group | group <- equivClassesByUniq get_uniq tc_inst_infos,
			      group `lengthExceeds` 1]
	get_uniq (tc,_) = getUnique tc

    mapM (addErrTc . dupGenericInsts) bad_groups

	-- Check that there is an InstInfo for each generic type constructor
    let
	missing = genericTyConNames `minusList` [tyConName tc | (tc,_) <- tc_inst_infos]

    checkTc (null missing) (missingGenericInstances missing)

    return inst_infos
  where
    generic_binds :: [(HsType Name, LHsBind Name)]
    generic_binds = getGenericBinds def_methods
get_generics decl = pprPanic "get_generics" (ppr decl)


---------------------------------
getGenericBinds :: LHsBinds Name -> [(HsType Name, LHsBind Name)]
  -- Takes a group of method bindings, finds the generic ones, and returns
  -- them in finite map indexed by the type parameter in the definition.
getGenericBinds binds = concat (map getGenericBind (bagToList binds))

getGenericBind :: LHsBindLR Name Name -> [(HsType Name, LHsBindLR Name Name)]
getGenericBind (L loc bind@(FunBind { fun_matches = MatchGroup matches ty }))
  = groupWith wrap (mapCatMaybes maybeGenericMatch matches)
  where
    wrap ms = L loc (bind { fun_matches = MatchGroup ms ty })
getGenericBind _
  = []

groupWith :: ([a] -> b) -> [(HsType Name, a)] -> [(HsType Name, b)]
groupWith _  [] 	 = []
groupWith op ((t,v):prs) = (t, op (v:vs)) : groupWith op rest
    where
      vs              = map snd this
      (this,rest)     = partition same_t prs
      same_t (t', _v) = t `eqPatType` t'

eqPatLType :: LHsType Name -> LHsType Name -> Bool
eqPatLType t1 t2 = unLoc t1 `eqPatType` unLoc t2

eqPatType :: HsType Name -> HsType Name -> Bool
-- A very simple equality function, only for 
-- type patterns in generic function definitions.
eqPatType (HsTyVar v1)       (HsTyVar v2)    	= v1==v2
eqPatType (HsAppTy s1 t1)    (HsAppTy s2 t2) 	= s1 `eqPatLType` s2 && t1 `eqPatLType` t2
eqPatType (HsOpTy s1 op1 t1) (HsOpTy s2 op2 t2) = s1 `eqPatLType` s2 && t1 `eqPatLType` t2 && unLoc op1 == unLoc op2
eqPatType (HsNumTy n1)	     (HsNumTy n2)	= n1 == n2
eqPatType (HsParTy t1)	     t2			= unLoc t1 `eqPatType` t2
eqPatType t1		     (HsParTy t2)	= t1 `eqPatType` unLoc t2
eqPatType _ _ = False

---------------------------------
mkGenericInstance :: Class
		  -> (HsType Name, LHsBinds Name)
		  -> TcM InstInfo

mkGenericInstance clas (hs_ty, binds) = do
  -- Make a generic instance declaration
  -- For example:	instance (C a, C b) => C (a+b) where { binds }

	-- Extract the universally quantified type variables
	-- and wrap them as forall'd tyvars, so that kind inference
	-- works in the standard way
    let
	sig_tvs = map (noLoc.UserTyVar) (nameSetToList (extractHsTyVars (noLoc hs_ty)))
	hs_forall_ty = noLoc $ mkExplicitHsForAllTy sig_tvs (noLoc []) (noLoc hs_ty)

	-- Type-check the instance type, and check its form
    forall_inst_ty <- tcHsSigType GenPatCtxt hs_forall_ty
    let
	(tyvars, inst_ty) = tcSplitForAllTys forall_inst_ty

    checkTc (validGenericInstanceType inst_ty)
            (badGenericInstanceType binds)

	-- Make the dictionary function.
    span <- getSrcSpanM
    overlap_flag <- getOverlapFlag
    dfun_name <- newDFunName clas [inst_ty] span
    let
	inst_theta = [mkClassPred clas [mkTyVarTy tv] | tv <- tyvars]
	dfun_id    = mkDictFunId dfun_name tyvars inst_theta clas [inst_ty]
	ispec	   = mkLocalInstance dfun_id overlap_flag

    return (InstInfo { iSpec = ispec, iBinds = VanillaInst binds [] })
\end{code}


%************************************************************************
%*									*
		Error messages
%*									*
%************************************************************************

\begin{code}
tcAddDeclCtxt :: TyClDecl Name -> TcM a -> TcM a
tcAddDeclCtxt decl thing_inside
  = addErrCtxt ctxt thing_inside
  where
     thing | isClassDecl decl  = "class"
	   | isTypeDecl decl   = "type synonym" ++ maybeInst
	   | isDataDecl decl   = if tcdND decl == NewType 
				 then "newtype" ++ maybeInst
				 else "data type" ++ maybeInst
	   | isFamilyDecl decl = "family"
	   | otherwise         = panic "tcAddDeclCtxt/thing"

     maybeInst | isFamInstDecl decl = " instance"
	       | otherwise          = ""

     ctxt = hsep [ptext (sLit "In the"), text thing, 
		  ptext (sLit "declaration for"), quotes (ppr (tcdName decl))]

defltMethCtxt :: Class -> SDoc
defltMethCtxt clas
  = ptext (sLit "When checking the default methods for class") <+> quotes (ppr clas)

methodCtxt :: Var -> SDoc
methodCtxt sel_id
  = ptext (sLit "In the definition for method") <+> quotes (ppr sel_id)

badMethodErr :: Outputable a => a -> Name -> SDoc
badMethodErr clas op
  = hsep [ptext (sLit "Class"), quotes (ppr clas), 
	  ptext (sLit "does not have a method"), quotes (ppr op)]

badATErr :: Class -> Name -> SDoc
badATErr clas at
  = hsep [ptext (sLit "Class"), quotes (ppr clas), 
	  ptext (sLit "does not have an associated type"), quotes (ppr at)]

omittedMethodWarn :: Id -> SDoc
omittedMethodWarn sel_id
  = ptext (sLit "No explicit method nor default method for") <+> quotes (ppr sel_id)

omittedATWarn :: Name -> SDoc
omittedATWarn at
  = ptext (sLit "No explicit AT declaration for") <+> quotes (ppr at)

badGenericInstance :: Var -> SDoc -> SDoc
badGenericInstance sel_id because
  = sep [ptext (sLit "Can't derive generic code for") <+> quotes (ppr sel_id),
	 because]

notSimple :: [Type] -> SDoc
notSimple inst_tys
  = vcat [ptext (sLit "because the instance type(s)"), 
	  nest 2 (ppr inst_tys),
	  ptext (sLit "is not a simple type of form (T a1 ... an)")]

notGeneric :: TyCon -> SDoc
notGeneric tycon
  = vcat [ptext (sLit "because the instance type constructor") <+> quotes (ppr tycon) <+> 
	  ptext (sLit "was not compiled with -fgenerics")]

badGenericInstanceType :: LHsBinds Name -> SDoc
badGenericInstanceType binds
  = vcat [ptext (sLit "Illegal type pattern in the generic bindings"),
	  nest 4 (ppr binds)]

missingGenericInstances :: [Name] -> SDoc
missingGenericInstances missing
  = ptext (sLit "Missing type patterns for") <+> pprQuotedList missing
	  
dupGenericInsts :: [(TyCon, InstInfo)] -> SDoc
dupGenericInsts tc_inst_infos
  = vcat [ptext (sLit "More than one type pattern for a single generic type constructor:"),
	  nest 4 (vcat (map ppr_inst_ty tc_inst_infos)),
	  ptext (sLit "All the type patterns for a generic type constructor must be identical")
    ]
  where 
    ppr_inst_ty (_,inst) = ppr (simpleInstInfoTy inst)

mixedGenericErr :: Name -> SDoc
mixedGenericErr op
  = ptext (sLit "Can't mix generic and non-generic equations for class method") <+> quotes (ppr op)
\end{code}
